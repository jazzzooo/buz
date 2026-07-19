pub const YAML = struct {
    const ParseError = OOM || error{ SyntaxError, StackOverflow };

    pub fn parse(source: *const logger.Source, log: *logger.Log, allocator: std.mem.Allocator) ParseError!Expr {
        bun.analytics.Features.yaml_parse += 1;

        var parser: Parser(.utf8) = .init(allocator, source.contents);

        const roots = parser.parse() catch |e| {
            const err = parser.errorDetails(e);
            try err.addToLog(source, log);
            return error.SyntaxError;
        };

        return switch (roots.items.len) {
            0 => .init(E.Null, .{}, .Empty),
            1 => roots.items[0],
            else => {
                // multi-document yaml streams are converted into arrays

                var items: bun.BabyList(Expr) = try .initCapacity(allocator, roots.items.len);

                for (roots.items) |root| {
                    items.appendAssumeCapacity(root);
                }

                return .init(E.Array, .{ .items = items }, .Empty);
            },
        };
    }
};

pub const Context = enum {
    block_out,
    block_in,
    flow_in,
    flow_key,

    pub const Stack = struct {
        list: std.array_list.Managed(Context),

        pub fn init(allocator: std.mem.Allocator) Stack {
            return .{ .list = .init(allocator) };
        }

        pub fn set(this: *@This(), context: Context) OOM!void {
            try this.list.append(context);
        }

        pub fn unset(this: *@This(), context: Context) void {
            const prev_context = this.list.pop();
            bun.assert(prev_context != null and prev_context.? == context);
        }

        pub fn get(this: *const @This()) Context {
            // top level context is always BLOCK-OUT
            return this.list.getLastOrNull() orelse .block_out;
        }
    };
};

pub const Chomp = enum {
    /// '-'
    /// remove all trailing newlines
    strip,
    /// ''
    /// exclude the last trailing newline (default)
    clip,
    /// '+'
    /// include all trailing newlines
    keep,

    pub const default: Chomp = .clip;
};

pub const Indent = enum(usize) {
    none = 0,
    _,

    pub fn from(indent: usize) Indent {
        return @fromBackingInt(@intCast(indent));
    }

    pub fn cast(indent: Indent) usize {
        return @backingInt(indent);
    }

    pub fn inc(indent: *Indent, n: usize) void {
        indent.* = @fromBackingInt(@intCast(@backingInt(indent.*) + n));
    }

    pub fn add(indent: Indent, n: usize) Indent {
        return @fromBackingInt(@intCast(@backingInt(indent) + n));
    }

    pub fn isLessThan(indent: Indent, other: Indent) bool {
        return @backingInt(indent) < @backingInt(other);
    }

    pub fn isLessThanOrEqual(indent: Indent, other: Indent) bool {
        return @backingInt(indent) <= @backingInt(other);
    }

    pub fn cmp(l: Indent, r: Indent) std.math.Order {
        if (@backingInt(l) > @backingInt(r)) return .gt;
        if (@backingInt(l) < @backingInt(r)) return .lt;
        return .eq;
    }

    pub const Indicator = enum(u8) {
        /// trim leading indentation (spaces) (default)
        auto = 0,

        @"1",
        @"2",
        @"3",
        @"4",
        @"5",
        @"6",
        @"7",
        @"8",
        @"9",

        pub const default: Indicator = .auto;

        pub fn get(indicator: Indicator) u8 {
            return @backingInt(indicator);
        }
    };

    pub const Stack = struct {
        list: std.array_list.Managed(Indent),

        pub fn init(allocator: std.mem.Allocator) Stack {
            return .{ .list = .init(allocator) };
        }

        pub fn push(this: *@This(), indent: Indent) OOM!void {
            try this.list.append(indent);
        }

        pub fn pop(this: *@This()) void {
            bun.assert(this.list.items.len != 0);
            _ = this.list.pop();
        }

        pub fn get(this: *@This()) ?Indent {
            return this.list.getLastOrNull();
        }
    };
};

pub const Pos = enum(usize) {
    zero = 0,
    _,

    pub fn from(pos: usize) Pos {
        return @fromBackingInt(@intCast(pos));
    }

    pub fn cast(pos: Pos) usize {
        return @backingInt(pos);
    }

    pub fn loc(pos: Pos) logger.Loc {
        return .{ .start = @intCast(@backingInt(pos)) };
    }

    pub fn add(pos: Pos, n: usize) Pos {
        return @fromBackingInt(@intCast(@backingInt(pos) + n));
    }

    pub fn sub(pos: Pos, n: usize) Pos {
        return @fromBackingInt(@intCast(@backingInt(pos) - n));
    }

    pub fn isLessThan(pos: Pos, other: usize) bool {
        return pos.cast() < other;
    }
};

pub const Line = enum(usize) {
    _,

    pub fn from(line: usize) Line {
        return @fromBackingInt(@intCast(line));
    }

    pub fn inc(line: *Line, n: usize) void {
        line.* = @fromBackingInt(@intCast(@backingInt(line.*) + n));
    }
};

comptime {
    bun.assert(Pos != Indent);
    bun.assert(Pos != Line);
    bun.assert(Indent != Line);
}

pub fn Parser(comptime enc: Encoding) type {
    const chars = enc.chars();

    return struct {
        input: []const enc.unit(),

        pos: Pos,
        line_indent: Indent,
        tab_after_indent: bool,
        line: Line,
        token: Token(enc),

        allocator: std.mem.Allocator,

        context: Context.Stack,
        block_indents: Indent.Stack,

        explicit_document_start_line: ?Line,

        anchors: bun.StringHashMap(Expr),

        tag_handles: bun.StringHashMap(void),

        whitespace_buf: std.array_list.Managed(Whitespace),

        stack_check: bun.StackCheck,
        merge_props_budget: usize,
        alias_expansion: AliasExpansion,

        const Whitespace = union(enum) {
            source: struct {
                pos: Pos,
                unit: enc.unit(),
            },
            new: enc.unit(),
        };

        pub fn init(allocator: std.mem.Allocator, input: []const enc.unit()) @This() {
            const start = Pos.from(enc.bomLen(input));
            return .{
                .input = input,
                .allocator = allocator,
                .pos = start,
                .line_indent = .none,
                .tab_after_indent = false,
                .line = .from(1),
                .token = .eof(.{ .start = start, .indent = .none, .line = .from(1) }),
                .context = .init(allocator),
                .block_indents = .init(allocator),
                .explicit_document_start_line = null,
                .anchors = .init(allocator),
                .tag_handles = .init(allocator),
                .whitespace_buf = .init(allocator),
                .stack_check = .init(),
                .merge_props_budget = MappingProps.max_merged_properties,
                .alias_expansion = .init(allocator),
            };
        }

        pub fn deinit(self: *@This()) void {
            self.context.list.deinit();
            self.block_indents.list.deinit();
            self.anchors.deinit();
            self.tag_handles.deinit();
            self.whitespace_buf.deinit();
            self.alias_expansion.deinit();
        }

        const Diagnostic = struct {
            kind: Kind,
            pos: Pos,

            const Kind = enum {
                oom,
                stack_overflow,
                unexpected_eof,
                unexpected_token,
                unexpected_character,
                invalid_directive,
                unresolved_tag_handle,
                unresolved_alias,
                multiline_implicit_key,
                multiple_anchors,
                multiple_tags,
                unexpected_document_start,
                unexpected_document_end,
                multiple_yaml_directives,
                invalid_indentation,
                excessive_aliasing,
            };

            pub fn addToLog(this: *const Diagnostic, source: *const logger.Source, log: *logger.Log) (OOM || error{StackOverflow})!void {
                const message = switch (this.kind) {
                    .oom => return error.OutOfMemory,
                    .stack_overflow => return error.StackOverflow,
                    .unexpected_eof => "Unexpected EOF",
                    .unexpected_token => "Unexpected token",
                    .unexpected_character => "Unexpected character",
                    .invalid_directive => "Invalid directive",
                    .unresolved_tag_handle => "Unresolved tag handle",
                    .unresolved_alias => "Unresolved alias",
                    .multiline_implicit_key => "Multiline implicit key",
                    .multiple_anchors => "Multiple anchors",
                    .multiple_tags => "Multiple tags",
                    .unexpected_document_start => "Unexpected document start",
                    .unexpected_document_end => "Unexpected document end",
                    .multiple_yaml_directives => "Multiple YAML directives",
                    .invalid_indentation => "Tab characters cannot be used as indentation",
                    .excessive_aliasing => "Excessive aliasing",
                };
                try log.addError(source, this.pos.loc(), message);
            }
        };

        fn errorDetails(self: *const @This(), err: ParseError) Diagnostic {
            return switch (err) {
                error.OutOfMemory => .{ .kind = .oom, .pos = self.pos },
                error.StackOverflow => .{ .kind = .stack_overflow, .pos = self.pos },
                error.UnexpectedToken => .{ .kind = .unexpected_token, .pos = self.token.start },
                error.UnexpectedEof => .{ .kind = .unexpected_eof, .pos = self.token.start },
                error.InvalidDirective => .{ .kind = .invalid_directive, .pos = self.token.start },
                error.UnexpectedCharacter => if (!self.pos.isLessThan(self.input.len))
                    .{ .kind = .unexpected_eof, .pos = self.pos }
                else
                    .{ .kind = .unexpected_character, .pos = self.pos },
                error.UnresolvedTagHandle => .{ .kind = .unresolved_tag_handle, .pos = self.pos },
                error.UnresolvedAlias => .{ .kind = .unresolved_alias, .pos = self.token.start },
                error.MultilineImplicitKey => .{ .kind = .multiline_implicit_key, .pos = self.token.start },
                error.MultipleAnchors => .{ .kind = .multiple_anchors, .pos = self.token.start },
                error.MultipleTags => .{ .kind = .multiple_tags, .pos = self.token.start },
                error.UnexpectedDocumentStart => .{ .kind = .unexpected_document_start, .pos = self.pos },
                error.UnexpectedDocumentEnd => .{ .kind = .unexpected_document_end, .pos = self.pos },
                error.MultipleYamlDirectives => .{ .kind = .multiple_yaml_directives, .pos = self.token.start },
                error.InvalidIndentation => .{ .kind = .invalid_indentation, .pos = self.pos },
                error.ExcessiveAliasing => .{ .kind = .excessive_aliasing, .pos = self.token.start },
            };
        }

        fn unexpectedToken() error{UnexpectedToken} {
            return error.UnexpectedToken;
        }

        fn parse(self: *@This()) ParseError!std.array_list.Managed(Expr) {
            try self.scan(.{ .first_scan = true });

            var roots: std.array_list.Managed(Expr) = .init(self.allocator);

            // we want one null document if eof, not zero documents.
            var first = true;
            while (first or self.token.data != .eof) {
                first = false;
                try roots.append(try self.parseDocument());
            }

            return roots;
        }

        const ParseError = OOM || error{
            UnexpectedToken,
            UnexpectedEof,
            InvalidDirective,
            UnexpectedCharacter,
            UnresolvedTagHandle,
            UnresolvedAlias,
            MultilineImplicitKey,
            MultipleAnchors,
            MultipleTags,
            UnexpectedDocumentStart,
            UnexpectedDocumentEnd,
            MultipleYamlDirectives,
            InvalidIndentation,
            ExcessiveAliasing,
            StackOverflow,
        };

        fn peek(self: *const @This(), comptime n: usize) enc.unit() {
            const pos = self.pos.add(n);
            if (pos.isLessThan(self.input.len)) {
                return self.input[pos.cast()];
            }

            return 0;
        }

        fn inc(self: *@This(), n: usize) void {
            self.pos = .from(@min(self.pos.cast() + n, self.input.len));
        }

        fn newline(self: *@This()) void {
            self.line_indent = .none;
            self.tab_after_indent = false;
            self.line.inc(1);
        }

        fn slice(self: *const @This(), off: Pos, end: Pos) []const enc.unit() {
            return self.input[off.cast()..end.cast()];
        }

        fn remain(self: *const @This()) []const enc.unit() {
            return self.input[self.pos.cast()..];
        }

        fn remainStartsWith(self: *const @This(), cs: []const enc.unit()) bool {
            return std.mem.startsWith(enc.unit(), self.remain(), cs);
        }

        // this looks different from node parsing code because directives
        // exist mostly outside of the normal token scanning logic. they are
        // not part of the root expression.

        // TODO: move most of this into `scan()`
        fn parseDirective(self: *@This()) ParseError!Directive {
            if (self.token.indent != .none) {
                return error.InvalidDirective;
            }

            // yaml directive
            if (self.remainStartsWith(enc.literal("YAML")) and self.isSWhiteAt(4)) {
                self.inc(4);

                try self.trySkipSWhite();
                try self.trySkipNsDecDigits();
                try self.trySkipChar('.');
                try self.trySkipNsDecDigits();

                // s-l-comments
                try self.trySkipToNewLine();

                return .yaml;
            }

            // tag directive
            if (self.remainStartsWith(enc.literal("TAG")) and self.isSWhiteAt(3)) {
                self.inc(3);

                try self.trySkipSWhite();
                try self.trySkipChar('!');

                // primary tag handle
                if (self.isSWhite()) {
                    self.skipSWhite();
                    try self.parseDirectiveTagPrefix();
                    try self.trySkipToNewLine();
                    return .other;
                }

                // secondary tag handle
                if (self.isChar('!')) {
                    self.inc(1);
                    try self.trySkipSWhite();
                    try self.parseDirectiveTagPrefix();
                    try self.trySkipToNewLine();
                    return .other;
                }

                // named tag handle
                var range = self.stringRange();
                try self.trySkipNsWordChars();
                const handle = range.end();
                try self.trySkipChar('!');
                try self.trySkipSWhite();

                try self.tag_handles.put(handle.slice(self.input), {});

                try self.parseDirectiveTagPrefix();
                try self.trySkipToNewLine();
                return .other;
            }

            // reserved directive
            try self.trySkipNsChars();

            self.skipSWhite();

            while (self.isNsChar()) {
                self.skipNsChars();
                self.skipSWhite();
            }

            try self.trySkipToNewLine();

            return .other;
        }

        fn parseDirectiveTagPrefix(self: *@This()) ParseError!void {
            // local tag prefix
            if (self.isChar('!')) {
                self.inc(1);
                self.skipNsUriChars();
                return;
            }

            // global tag prefix
            if (self.isNsTagChar()) |char_len| {
                self.inc(char_len);
                self.skipNsUriChars();
                return;
            }

            return error.InvalidDirective;
        }

        fn parseDocument(self: *@This()) ParseError!Expr {
            self.anchors.clearRetainingCapacity();
            self.tag_handles.clearRetainingCapacity();

            var has_directives = false;
            var has_yaml_directive = false;

            while (self.token.data == .directive) {
                has_directives = true;
                const directive = try self.parseDirective();
                if (directive == .yaml) {
                    if (has_yaml_directive) {
                        return error.MultipleYamlDirectives;
                    }
                    has_yaml_directive = true;
                }
                try self.scan(.{});
            }

            self.explicit_document_start_line = null;

            if (self.token.data == .document_start) {
                self.explicit_document_start_line = self.token.line;
                try self.scan(.{});
            } else if (has_directives) {
                // if there's directives they must end with '---'
                return unexpectedToken();
            }

            const root = try self.parseNode(.{});

            // If document_start it needs to create a new document.
            // If document_end, consume as many as possible. They should
            // not create new documents.
            switch (self.token.data) {
                .eof => {},
                .document_start => {},
                .document_end => {
                    var document_end_line = self.token.line;

                    // consume all bare documents
                    while (self.token.data == .document_end) {
                        document_end_line = self.token.line;
                        try self.scan(.{});
                    }

                    if (self.token.data != .eof and self.token.line == document_end_line) {
                        return unexpectedToken();
                    }
                },
                else => {
                    return unexpectedToken();
                },
            }

            return root;
        }

        fn parseFlowSequence(self: *@This()) ParseError!Expr {
            const sequence_start = self.token.start;

            var seq: std.array_list.Managed(Expr) = .init(self.allocator);

            {
                try self.context.set(.flow_in);
                defer self.context.unset(.flow_in);

                try self.scan(.{});
                while (self.token.data != .sequence_end) {
                    const item = if (self.token.data == .mapping_key)
                        try self.flowPairExpr(try self.parseFlowExplicitPair())
                    else item: {
                        const key_line = self.token.line;
                        const key = key: {
                            try self.context.set(.flow_key);
                            defer self.context.unset(.flow_key);
                            break :key try self.parseNode(.{ .flow_pair_allowed = false });
                        };

                        if (self.token.data != .mapping_value) break :item key;
                        if (self.token.line != key_line) return error.MultilineImplicitKey;
                        break :item try self.flowPairExpr(try self.parseFlowPairValue(key, Pos.from(key.loc.i())));
                    };
                    try seq.append(item);

                    if (self.token.data == .sequence_end) {
                        break;
                    }

                    if (self.token.data != .collect_entry) {
                        return unexpectedToken();
                    }

                    try self.scan(.{});
                }
            }

            try self.scan(.{});

            return .init(E.Array, .{ .items = .moveFromList(&seq) }, sequence_start.loc());
        }

        const FlowPair = struct {
            key: Expr,
            value: Expr,
            start: Pos,
        };

        fn parseFlowExplicitPair(self: *@This()) ParseError!FlowPair {
            const pair_start = self.token.start;
            try self.scan(.{});

            const key: Expr = switch (self.token.data) {
                .mapping_value,
                .collect_entry,
                .sequence_end,
                .mapping_end,
                => .init(E.Null, .{}, self.token.start.loc()),
                .mapping_key => return unexpectedToken(),
                .anchor, .tag => try self.parseNode(.{ .flow_pair_allowed = false }),
                else => key: {
                    try self.context.set(.flow_key);
                    defer self.context.unset(.flow_key);
                    break :key try self.parseNode(.{ .flow_pair_allowed = false });
                },
            };

            if (self.token.data == .mapping_value) {
                return self.parseFlowPairValue(key, pair_start);
            }

            const value: Expr = .init(E.Null, .{}, self.token.start.loc());
            return .{ .key = key, .value = value, .start = pair_start };
        }

        fn parseFlowPairValue(self: *@This(), key: Expr, pair_start: Pos) ParseError!FlowPair {
            try self.scan(.{});

            const value: Expr = switch (self.token.data) {
                .collect_entry, .sequence_end, .mapping_end => .init(E.Null, .{}, self.token.start.loc()),
                .mapping_key => return unexpectedToken(),
                else => try self.parseNode(.{ .flow_pair_allowed = false }),
            };
            return .{ .key = key, .value = value, .start = pair_start };
        }

        fn flowPairExpr(self: *@This(), pair: FlowPair) ParseError!Expr {
            var props: MappingProps = .init(self.allocator);
            defer props.deinit();
            try props.appendMaybeMerge(pair.key, pair.value, &self.merge_props_budget);
            return .init(E.Object, .{ .properties = props.moveList() }, pair.start.loc());
        }

        fn parseFlowMapping(self: *@This()) ParseError!Expr {
            const mapping_start = self.token.start;

            var props: MappingProps = .init(self.allocator);
            defer props.deinit();

            {
                try self.context.set(.flow_in);
                defer self.context.unset(.flow_in);

                {
                    try self.context.set(.flow_key);
                    defer self.context.unset(.flow_key);
                    try self.scan(.{});
                }

                while (self.token.data != .mapping_end) {
                    if (self.token.data == .collect_entry) return unexpectedToken();

                    const pair: FlowPair = if (self.token.data == .mapping_key)
                        try self.parseFlowExplicitPair()
                    else pair: {
                        const key: Expr = if (self.token.data == .mapping_value)
                            .init(E.Null, .{}, self.token.start.loc())
                        else key: {
                            try self.context.set(.flow_key);
                            defer self.context.unset(.flow_key);
                            break :key try self.parseNode(.{ .flow_pair_allowed = false });
                        };

                        if (self.token.data == .mapping_value) {
                            break :pair try self.parseFlowPairValue(key, Pos.from(key.loc.i()));
                        }

                        const value: Expr = .init(E.Null, .{}, self.token.start.loc());
                        break :pair .{ .key = key, .value = value, .start = Pos.from(key.loc.i()) };
                    };

                    try props.appendMaybeMerge(pair.key, pair.value, &self.merge_props_budget);

                    if (self.token.data == .mapping_end) break;
                    if (self.token.data != .collect_entry) return unexpectedToken();

                    {
                        try self.context.set(.flow_key);
                        defer self.context.unset(.flow_key);
                        try self.scan(.{});
                    }
                }
            }

            try self.scan(.{});

            return .init(E.Object, .{ .properties = props.moveList() }, mapping_start.loc());
        }

        fn parseBlockSequence(self: *@This(), explicit_mapping_indent: ?Indent) ParseError!Expr {
            const sequence_start = self.token.start;
            const sequence_indent = self.token.indent;
            const sequence_line = self.token.line;

            if (self.explicit_document_start_line) |document_start_line| {
                if (document_start_line == sequence_line) return unexpectedToken();
            }

            try self.block_indents.push(sequence_indent);
            defer self.block_indents.pop();

            var seq: std.array_list.Managed(Expr) = .init(self.allocator);

            var prev_line: Line = .from(0);

            while (self.token.data == .sequence_entry and self.token.indent == sequence_indent) {
                try self.rejectTabAsIndentation(self.token.tab_after_indent);

                const entry_line = self.token.line;
                const entry_start = self.token.start;

                if (seq.items.len != 0 and prev_line == self.token.line) {
                    // only the first entry can be another sequence entry on the
                    // same line
                    break;
                }

                prev_line = self.token.line;
                try self.scan(.{ .additional_parent_indent = sequence_indent.add(1) });
                const item = try self.parseBlockIndented(
                    sequence_indent,
                    entry_line,
                    entry_start.add(2),
                    .{ .sequence_entry = explicit_mapping_indent },
                );
                try seq.append(item);
            }

            return .init(E.Array, .{ .items = .moveFromList(&seq) }, sequence_start.loc());
        }

        /// Should only be used with expressions created with the YAML parser. It assumes
        /// only null, boolean, number, string, array, object are possible. It also only
        /// does pointer comparison with arrays and objects (so exponential merges are avoided)
        fn yamlMergeKeyExprEql(l: Expr, r: Expr) bool {
            if (std.meta.activeTag(l.data) != std.meta.activeTag(r.data)) {
                return false;
            }

            return switch (l.data) {
                .e_null => true,
                .e_boolean => |l_boolean| l_boolean.value == r.data.e_boolean.value,
                .e_number => |l_number| l_number.value == r.data.e_number.value,
                .e_string => |l_string| l_string.eql(E.String, r.data.e_string),

                .e_array => |l_array| l_array == r.data.e_array,
                .e_object => |l_object| l_object == r.data.e_object,

                else => false,
            };
        }

        fn yamlMergeKeyExprHash(key: Expr) u64 {
            return switch (key.data) {
                .e_null => 0,
                .e_boolean => |boolean| 1 + @as(u64, @intFromBool(boolean.value)),
                .e_number => |number| @bitCast(if (number.value == 0) @as(f64, 0) else number.value),
                .e_string => |string| string.hash(),
                .e_array => |array| @intCast(@intFromPtr(array)),
                .e_object => |object| @intCast(@intFromPtr(object)),
                else => std.math.maxInt(u64),
            };
        }

        const MappingProps = struct {
            const MergeKeyContext = struct {
                pub fn hash(_: @This(), key: Expr) u64 {
                    return yamlMergeKeyExprHash(key);
                }

                pub fn eql(_: @This(), l: Expr, r: Expr) bool {
                    return yamlMergeKeyExprEql(l, r);
                }
            };

            const MergeKeyIndex = std.HashMap(
                Expr,
                void,
                MergeKeyContext,
                std.hash_map.default_max_load_percentage,
            );

            /// Bounds amplification from a small document merging one large anchor many times.
            pub const max_merged_properties = 1024 * 1024;

            list: bun.collections.ArrayList(G.Property),
            key_index: MergeKeyIndex,
            merged_objects: std.AutoHashMap(*const E.Object, void),
            indexed_count: usize = 0,

            pub fn init(allocator: std.mem.Allocator) MappingProps {
                return .{
                    .list = .initIn(allocator),
                    .key_index = .init(allocator),
                    .merged_objects = .init(allocator),
                };
            }

            pub fn deinit(self: *MappingProps) void {
                self.list.deinitShallow();
                self.key_index.deinit();
                self.merged_objects.deinit();
            }

            fn merge(self: *MappingProps, merge_props: []const G.Property, budget: *usize) OOM!void {
                try self.list.ensureUnusedCapacity(@min(merge_props.len, budget.*));

                while (self.indexed_count < self.list.items().len) : (self.indexed_count += 1) {
                    const existing_key = self.list.items()[self.indexed_count].key.?;
                    _ = try self.key_index.getOrPut(existing_key);
                }

                var iter = std.mem.reverseIterator(merge_props);
                while (iter.next()) |merge_prop| {
                    const merge_key = merge_prop.key.?;
                    const indexed = try self.key_index.getOrPut(merge_key);
                    if (indexed.found_existing) continue;

                    if (budget.* == 0) return error.OutOfMemory;
                    budget.* -= 1;
                    self.list.appendAssumeCapacity(merge_prop);
                    self.indexed_count = self.list.items().len;
                }
            }

            fn mergeObject(self: *MappingProps, object: *const E.Object, budget: *usize) OOM!void {
                const merged = try self.merged_objects.getOrPut(object);
                if (merged.found_existing) return;
                try self.merge(object.properties.slice(), budget);
            }

            pub fn append(self: *MappingProps, prop: G.Property) OOM!void {
                try self.list.append(prop);
            }

            pub fn appendMaybeMerge(self: *MappingProps, key: Expr, value: Expr, budget: *usize) OOM!void {
                if (switch (key.data) {
                    .e_string => |key_str| !key_str.eqlComptime("<<"),
                    else => true,
                }) {
                    return self.list.append(.{ .key = key, .value = value });
                }

                return switch (value.data) {
                    .e_object => |value_obj| self.mergeObject(value_obj, budget),
                    .e_array => |value_arr| {
                        for (value_arr.items.slice()) |item| {
                            const item_obj = switch (item.data) {
                                .e_object => |obj| obj,
                                else => continue,
                            };

                            try self.mergeObject(item_obj, budget);
                        }
                    },

                    else => self.list.append(.{ .key = key, .value = value }),
                };
            }

            pub fn moveList(self: *MappingProps) G.Property.List {
                return .moveFromList(&self.list);
            }
        };

        fn parseBlockMapping(
            self: *@This(),
            first_key: Expr,
            mapping_start: Pos,
            mapping_indent: Indent,
            mapping_line: Line,
            tab_after_indent: bool,
            explicit_entry: bool,
        ) ParseError!Expr {
            try self.rejectTabAsIndentation(tab_after_indent);

            if (self.explicit_document_start_line) |explicit_document_start_line| {
                if (mapping_line == explicit_document_start_line) {
                    // TODO: more specific error
                    return error.UnexpectedToken;
                }
            }

            try self.block_indents.push(mapping_indent);
            defer self.block_indents.pop();

            var props: MappingProps = .init(self.allocator);
            defer props.deinit();

            {
                // get the first value

                const mapping_value_start = self.token.start;
                const mapping_value_line = self.token.line;

                if (explicit_entry and self.token.data == .mapping_value) {
                    switch (self.token.indent.cmp(mapping_indent)) {
                        .lt => {},
                        .eq => {},
                        .gt => return unexpectedToken(),
                    }
                }

                const value: Expr = if (explicit_entry and
                    self.token.data == .mapping_value and
                    self.token.indent.isLessThan(mapping_indent))
                    .init(E.Null, .{}, mapping_value_start.loc())
                else switch (self.token.data) {
                    // it's a !!set entry
                    .mapping_key => value: {
                        if (self.token.line == mapping_line) {
                            return unexpectedToken();
                        }
                        break :value .init(E.Null, .{}, mapping_value_start.loc());
                    },
                    .mapping_value => value: {
                        try self.rejectTabAsIndentation(self.token.tab_after_indent);
                        const parent_indent = if (mapping_value_line != mapping_line) mapping_indent.add(1) else null;
                        try self.scan(.{ .additional_parent_indent = parent_indent, .block_indented = true });
                        break :value try self.parseBlockIndented(
                            mapping_indent,
                            mapping_value_line,
                            mapping_value_start,
                            .{ .mapping_value = .{
                                .flow_pair_allowed = false,
                                .compact_mapping_allowed = mapping_value_line != mapping_line,
                            } },
                        );
                    },
                    else => .init(E.Null, .{}, mapping_value_start.loc()),
                };

                try props.appendMaybeMerge(first_key, value, &self.merge_props_budget);
            }

            if (self.context.get() == .flow_in) {
                return .init(E.Object, .{ .properties = props.moveList() }, mapping_start.loc());
            }

            try self.context.set(.block_in);
            defer self.context.unset(.block_in);

            var previous_line = mapping_line;

            while (switch (self.token.data) {
                .eof,
                .document_start,
                .document_end,
                => false,
                else => true,
            } and self.token.indent == mapping_indent and self.token.line != previous_line) {
                try self.rejectTabAsIndentation(self.token.tab_after_indent);

                const key_line = self.token.line;
                previous_line = key_line;
                const explicit_key = self.token.data == .mapping_key;

                const key = try self.parseNode(.{ .current_mapping_indent = mapping_indent });

                if (explicit_key) {
                    const has_value = self.token.data == .mapping_value and switch (self.token.indent.cmp(mapping_indent)) {
                        .lt => false,
                        .eq => true,
                        .gt => return unexpectedToken(),
                    };
                    if (!has_value) {
                        const value: Expr = .init(E.Null, .{}, self.token.start.loc());
                        try props.appendMaybeMerge(key, value, &self.merge_props_budget);
                        continue;
                    }
                }

                switch (self.token.data) {
                    .eof,
                    => {
                        if (explicit_key) {
                            const value: Expr = .init(E.Null, .{}, self.pos.loc());
                            try props.append(.{
                                .key = key,
                                .value = value,
                            });
                            continue;
                        }
                        return unexpectedToken();
                    },
                    .mapping_value => {
                        if (!explicit_key and key_line != self.token.line) {
                            return error.MultilineImplicitKey;
                        }
                    },
                    .mapping_key => {},
                    else => {
                        return unexpectedToken();
                    },
                }

                const mapping_value_start = self.token.start;
                const mapping_value_line = self.token.line;

                const value: Expr = switch (self.token.data) {
                    // it's a !!set entry
                    .mapping_key => value: {
                        if (self.token.line == key_line) {
                            return unexpectedToken();
                        }
                        break :value .init(E.Null, .{}, mapping_value_start.loc());
                    },
                    else => value: {
                        try self.rejectTabAsIndentation(self.token.tab_after_indent);
                        const parent_indent = if (mapping_value_line != key_line) mapping_indent.add(1) else null;
                        try self.scan(.{ .additional_parent_indent = parent_indent, .block_indented = true });
                        break :value try self.parseBlockIndented(
                            mapping_indent,
                            mapping_value_line,
                            mapping_value_start,
                            .{ .mapping_value = .{
                                .flow_pair_allowed = false,
                                .compact_mapping_allowed = mapping_value_line != key_line,
                            } },
                        );
                    },
                };

                try props.appendMaybeMerge(key, value, &self.merge_props_budget);
            }

            return .init(E.Object, .{ .properties = props.moveList() }, mapping_start.loc());
        }

        const NodeProperties = struct {
            // c-ns-properties
            has_anchor: ?Token(enc) = null,
            has_tag: ?Token(enc) = null,

            // when properties for mapping and first key
            // are right next to eachother
            // ```
            // &mapanchor !!map
            // &keyanchor !!bool true: false
            // ```
            has_mapping_anchor: ?Token(enc) = null,
            has_mapping_tag: ?Token(enc) = null,

            pub fn hasAnchorOrTag(this: *const NodeProperties) bool {
                return this.has_anchor != null or this.has_tag != null;
            }

            pub fn setAnchor(this: *NodeProperties, anchor_token: Token(enc)) error{MultipleAnchors}!void {
                if (this.has_anchor) |previous_anchor| {
                    if (previous_anchor.line == anchor_token.line) {
                        return error.MultipleAnchors;
                    }
                    if (this.has_mapping_anchor != null) {
                        return error.MultipleAnchors;
                    }

                    this.has_mapping_anchor = previous_anchor;
                }
                this.has_anchor = anchor_token;
            }

            pub fn anchor(this: *const NodeProperties) ?String.Range {
                return if (this.has_anchor) |anchor_token| anchor_token.data.anchor else null;
            }

            pub fn anchorLine(this: *const NodeProperties) ?Line {
                return if (this.has_anchor) |anchor_token| anchor_token.line else null;
            }

            const ImplicitKeyAnchors = struct {
                key_anchor: ?String.Range,
                mapping_anchor: ?String.Range,
            };

            pub fn implicitKeyAnchors(this: *const NodeProperties, implicit_key_line: Line) error{MultipleAnchors}!ImplicitKeyAnchors {
                if (this.has_mapping_anchor) |mapping_anchor| {
                    bun.assert(this.has_anchor != null);
                    if (this.has_anchor.?.line != implicit_key_line) {
                        return error.MultipleAnchors;
                    }
                    return .{
                        .key_anchor = if (this.has_anchor) |key_anchor| key_anchor.data.anchor else null,
                        .mapping_anchor = mapping_anchor.data.anchor,
                    };
                }

                if (this.has_anchor) |mystery_anchor| {
                    // might be the anchor for the key, or anchor for the mapping
                    if (mystery_anchor.line == implicit_key_line) {
                        return .{
                            .key_anchor = mystery_anchor.data.anchor,
                            .mapping_anchor = null,
                        };
                    }

                    return .{
                        .key_anchor = null,
                        .mapping_anchor = mystery_anchor.data.anchor,
                    };
                }

                return .{
                    .key_anchor = null,
                    .mapping_anchor = null,
                };
            }

            pub fn setTag(this: *NodeProperties, tag_token: Token(enc)) error{MultipleTags}!void {
                if (this.has_tag) |previous_tag| {
                    if (previous_tag.line == tag_token.line) {
                        return error.MultipleTags;
                    }
                    if (this.has_mapping_tag != null) {
                        return error.MultipleTags;
                    }

                    this.has_mapping_tag = previous_tag;
                }

                this.has_tag = tag_token;
            }

            pub fn tag(this: *const NodeProperties) NodeTag {
                return if (this.has_tag) |tag_token| tag_token.data.tag else .none;
            }

            pub fn tagLine(this: *const NodeProperties) ?Line {
                return if (this.has_tag) |tag_token| tag_token.line else null;
            }
        };

        const ParseNodeOptions = struct {
            current_mapping_indent: ?Indent = null,
            explicit_mapping_key: bool = false,
            flow_pair_allowed: bool = true,
            scanned_tag: ?Token(enc) = null,
            scanned_anchor: ?Token(enc) = null,
        };

        const BlockIndentedKind = union(enum) {
            sequence_entry: ?Indent,
            explicit_mapping_key,
            mapping_value: struct {
                flow_pair_allowed: bool,
                compact_mapping_allowed: bool,
            },

            pub fn isBlockOut(this: @This()) bool {
                return switch (this) {
                    .sequence_entry => false,
                    else => true,
                };
            }
        };

        fn finishNodeProperties(self: *@This(), node_props: NodeProperties, node: Expr) ParseError!Expr {
            if (node_props.has_mapping_anchor) |mapping_anchor| {
                self.token = mapping_anchor;
                return error.MultipleAnchors;
            }

            if (node_props.has_mapping_tag) |mapping_tag| {
                self.token = mapping_tag;
                return error.MultipleTags;
            }

            const resolved = switch (node.data) {
                .e_null => node_props.tag().resolveNull(node.loc),
                else => node,
            };

            if (node_props.anchor()) |anchor| {
                try self.anchors.put(anchor.slice(self.input), resolved);
            }

            return resolved;
        }

        fn parseBlockIndented(self: *@This(), n: Indent, indicator_line: Line, indicator_start: Pos, kind: BlockIndentedKind) ParseError!Expr {
            var node_props: NodeProperties = .{};
            properties: while (true) {
                if (self.token.line != indicator_line) {
                    const belongs_to_parent = if (self.token.data == .sequence_entry and kind.isBlockOut())
                        self.token.indent.isLessThan(n)
                    else
                        self.token.indent.isLessThanOrEqual(n);

                    if (belongs_to_parent) {
                        const has_tag = node_props.has_tag != null;
                        const is_plain_scalar = scalar: switch (self.token.data) {
                            .scalar => |scalar| {
                                if (scalar.multiline) break :scalar false;
                                if (self.token.start == .zero) break :scalar true;
                                break :scalar switch (self.input[self.token.start.sub(1).cast()]) {
                                    '\'', '"' => false,
                                    else => true,
                                };
                            },
                            else => false,
                        };

                        if (has_tag and is_plain_scalar) {
                            const scalar = self.token.data.scalar;
                            switch (scalar.data) {
                                .string => |value| {
                                    var string = value;
                                    string.deinit();
                                },
                                else => {},
                            }

                            self.pos = self.token.start;
                            self.line = self.token.line;
                            self.line_indent = self.token.indent;
                            self.tab_after_indent = self.token.tab_after_indent;
                            self.whitespace_buf.clearRetainingCapacity();
                            try self.scan(.{});
                        }

                        const empty_node: Expr = .init(E.Null, .{}, indicator_start.loc());
                        return self.finishNodeProperties(node_props, empty_node);
                    }
                }

                if (self.token.data == .mapping_key and
                    self.token.line == indicator_line and
                    self.token.indent.isLessThanOrEqual(n) and
                    switch (kind) {
                        .mapping_value => |opts| !opts.compact_mapping_allowed,
                        else => false,
                    })
                {
                    return unexpectedToken();
                }

                switch (self.token.data) {
                    .sequence_entry, .mapping_key, .mapping_value => try self.rejectTabAsIndentation(self.token.tab_after_indent),
                    else => {},
                }

                switch (self.token.data) {
                    .anchor => {
                        if (node_props.has_anchor != null) break;
                        try node_props.setAnchor(self.token);
                    },
                    .tag => {
                        if (node_props.has_tag != null) break;
                        try node_props.setTag(self.token);
                    },
                    .sequence_entry,
                    .mapping_key,
                    => {
                        if (self.token.line == indicator_line and self.token.indent.isLessThanOrEqual(n)) {
                            return unexpectedToken();
                        }
                        break;
                    },
                    .collect_entry,
                    .sequence_end,
                    => {
                        const flow_pair_allowed = switch (kind) {
                            .mapping_value => |opts| opts.flow_pair_allowed,
                            else => false,
                        };
                        if (flow_pair_allowed) {
                            switch (self.context.get()) {
                                .flow_in,
                                .flow_key,
                                => {
                                    const empty_node: Expr = .init(E.Null, .{}, indicator_start.loc());
                                    return self.finishNodeProperties(node_props, empty_node);
                                },
                                else => {},
                            }
                        }
                        break :properties;
                    },
                    else => break,
                }

                const tag = node_props.tag();
                try self.scan(.{ .tag = tag });
            }

            const explicit_mapping_indent = switch (kind) {
                .sequence_entry => |indent| indent,
                .explicit_mapping_key => n,
                else => null,
            };
            return self.parseNode(.{
                .current_mapping_indent = explicit_mapping_indent orelse n,
                .explicit_mapping_key = explicit_mapping_indent != null,
                .scanned_tag = node_props.has_tag,
                .scanned_anchor = node_props.has_anchor,
            });
        }

        const AliasExpansion = struct {
            const Error = OOM || error{ExcessiveAliasing};
            const max_nodes = 16 * 1024 * 1024;

            budget: usize = max_nodes,
            costs: std.AutoHashMap(*const anyopaque, usize),
            stack: std.array_list.Managed(Expr),

            fn init(allocator: std.mem.Allocator) AliasExpansion {
                return .{
                    .costs = .init(allocator),
                    .stack = .init(allocator),
                };
            }

            fn deinit(self: *AliasExpansion) void {
                self.costs.deinit();
                self.stack.deinit();
            }

            fn collectionKey(node: Expr) ?*const anyopaque {
                return switch (node.data) {
                    .e_array => |array| @ptrCast(array),
                    .e_object => |object| @ptrCast(object),
                    else => null,
                };
            }

            fn ensureCapacity(self: *AliasExpansion, cost: usize, additional: usize) Error!void {
                const remaining = self.budget - cost;
                if (self.stack.items.len > remaining or additional > remaining - self.stack.items.len) {
                    return error.ExcessiveAliasing;
                }
                try self.stack.ensureUnusedCapacity(additional);
            }

            fn charge(self: *AliasExpansion, root: Expr) Error!void {
                self.stack.clearRetainingCapacity();
                try self.ensureCapacity(0, 1);
                self.stack.appendAssumeCapacity(root);

                var cost: usize = 0;
                while (self.stack.pop()) |node| {
                    if (collectionKey(node)) |cache_key| {
                        if (self.costs.get(cache_key)) |cached_cost| {
                            if (cached_cost > self.budget - cost) return error.ExcessiveAliasing;
                            cost += cached_cost;
                            continue;
                        }
                    }

                    if (cost == self.budget) return error.ExcessiveAliasing;
                    cost += 1;

                    switch (node.data) {
                        .e_array => |array| {
                            const items = array.items.slice();
                            try self.ensureCapacity(cost, items.len);
                            self.stack.appendSliceAssumeCapacity(items);
                        },
                        .e_object => |object| {
                            var child_count: usize = 0;
                            for (object.properties.slice()) |prop| {
                                child_count += @intFromBool(prop.key != null);
                                child_count += @intFromBool(prop.value != null);
                            }

                            try self.ensureCapacity(cost, child_count);
                            for (object.properties.slice()) |prop| {
                                if (prop.key) |child| self.stack.appendAssumeCapacity(child);
                                if (prop.value) |child| self.stack.appendAssumeCapacity(child);
                            }
                        },
                        else => {},
                    }
                }

                if (collectionKey(root)) |cache_key| try self.costs.put(cache_key, cost);
                self.budget -= cost;
            }
        };

        fn isExplicitMappingValue(self: *const @This(), opts: ParseNodeOptions, node_line: Line) bool {
            switch (self.context.get()) {
                .block_out, .block_in => {},
                .flow_in, .flow_key => return false,
            }
            _ = opts.current_mapping_indent orelse return false;
            return opts.explicit_mapping_key and
                self.token.line != node_line;
        }

        fn parseNode(self: *@This(), opts: ParseNodeOptions) ParseError!Expr {
            if (!self.stack_check.isSafeToRecurse()) {
                try bun.throwStackOverflow();
            }

            // c-ns-properties
            var node_props: NodeProperties = .{};

            if (opts.scanned_tag) |tag| {
                try node_props.setTag(tag);
            }

            if (opts.scanned_anchor) |anchor| {
                try node_props.setAnchor(anchor);
            }

            const node: Expr = node: switch (self.token.data) {
                .eof,
                .document_start,
                .document_end,
                => {
                    break :node .init(E.Null, .{}, self.token.start.loc());
                },

                .anchor => |anchor| {
                    _ = anchor;
                    try node_props.setAnchor(self.token);

                    try self.scan(.{ .tag = node_props.tag() });

                    continue :node self.token.data;
                },

                .tag => |tag| {
                    try node_props.setTag(self.token);

                    try self.scan(.{ .tag = tag });

                    continue :node self.token.data;
                },

                .alias => |alias| {
                    const alias_start = self.token.start;
                    const alias_indent = self.token.indent;
                    const alias_line = self.token.line;
                    const alias_tab_after_indent = self.token.tab_after_indent;

                    if (node_props.has_anchor) |anchor| {
                        if (anchor.line == alias_line) {
                            return unexpectedToken();
                        }
                    }
                    if (node_props.has_tag) |tag| {
                        if (tag.line == alias_line) {
                            return unexpectedToken();
                        }
                    }

                    var copy = self.anchors.get(alias.slice(self.input)) orelse {
                        return error.UnresolvedAlias;
                    };

                    try self.alias_expansion.charge(copy);

                    // update position from the anchor node to the alias node.
                    copy.loc = alias_start.loc();

                    try self.scan(.{});

                    if (self.token.data == .mapping_value) {
                        if (self.isExplicitMappingValue(opts, alias_line)) break :node copy;

                        if (!opts.flow_pair_allowed and self.context.get() == .flow_in) {
                            break :node copy;
                        }

                        if (self.context.get() == .flow_key) {
                            return copy;
                        }

                        if (alias_line != self.token.line and !opts.explicit_mapping_key) {
                            return error.MultilineImplicitKey;
                        }

                        if (opts.current_mapping_indent) |current_mapping_indent| {
                            if (current_mapping_indent == alias_indent) {
                                return copy;
                            }
                        }

                        const map = try self.parseBlockMapping(
                            copy,
                            alias_start,
                            alias_indent,
                            alias_line,
                            alias_tab_after_indent,
                            false,
                        );

                        return map;
                    }

                    break :node copy;
                },

                .sequence_start => {
                    const sequence_start = self.token.start;
                    const sequence_indent = self.token.indent;
                    const sequence_line = self.token.line;
                    const sequence_tab_after_indent = self.token.tab_after_indent;
                    const seq = try self.parseFlowSequence();

                    if (self.token.data == .mapping_value) {
                        if (self.isExplicitMappingValue(opts, sequence_line)) break :node seq;

                        if (!opts.flow_pair_allowed and self.context.get() == .flow_in) {
                            break :node seq;
                        }

                        if (self.context.get() == .flow_key) {
                            break :node seq;
                        }

                        if (sequence_line != self.token.line and !opts.explicit_mapping_key) {
                            return error.MultilineImplicitKey;
                        }

                        if (opts.current_mapping_indent) |current_mapping_indent| {
                            if (current_mapping_indent == sequence_indent) {
                                break :node seq;
                            }
                        }

                        const implicit_key_anchors = try node_props.implicitKeyAnchors(sequence_line);

                        if (implicit_key_anchors.key_anchor) |key_anchor| {
                            try self.anchors.put(key_anchor.slice(self.input), seq);
                        }

                        const map = try self.parseBlockMapping(
                            seq,
                            sequence_start,
                            sequence_indent,
                            sequence_line,
                            sequence_tab_after_indent,
                            false,
                        );

                        if (implicit_key_anchors.mapping_anchor) |mapping_anchor| {
                            try self.anchors.put(mapping_anchor.slice(self.input), map);
                        }

                        return map;
                    }

                    break :node seq;
                },
                .collect_entry,
                .sequence_end,
                .mapping_end,
                => {
                    if (node_props.hasAnchorOrTag()) {
                        break :node .init(E.Null, .{}, self.pos.loc());
                    }
                    return unexpectedToken();
                },
                .sequence_entry => {
                    if (node_props.anchorLine()) |anchor_line| {
                        if (anchor_line == self.token.line) {
                            return unexpectedToken();
                        }
                    }
                    if (node_props.tagLine()) |tag_line| {
                        if (tag_line == self.token.line) {
                            return unexpectedToken();
                        }
                    }

                    const explicit_mapping_indent = if (opts.explicit_mapping_key)
                        opts.current_mapping_indent
                    else
                        null;
                    break :node try self.parseBlockSequence(explicit_mapping_indent);
                },
                .mapping_start => {
                    const mapping_start = self.token.start;
                    const mapping_indent = self.token.indent;
                    const mapping_line = self.token.line;
                    const mapping_tab_after_indent = self.token.tab_after_indent;

                    const map = try self.parseFlowMapping();

                    if (self.token.data == .mapping_value) {
                        if (self.isExplicitMappingValue(opts, mapping_line)) break :node map;

                        if (!opts.flow_pair_allowed and self.context.get() == .flow_in) {
                            break :node map;
                        }

                        if (self.context.get() == .flow_key) {
                            break :node map;
                        }

                        if (mapping_line != self.token.line and !opts.explicit_mapping_key) {
                            return error.MultilineImplicitKey;
                        }

                        if (opts.current_mapping_indent) |current_mapping_indent| {
                            if (current_mapping_indent == mapping_indent) {
                                break :node map;
                            }
                        }

                        const implicit_key_anchors = try node_props.implicitKeyAnchors(mapping_line);

                        if (implicit_key_anchors.key_anchor) |key_anchor| {
                            try self.anchors.put(key_anchor.slice(self.input), map);
                        }

                        const parent_map = try self.parseBlockMapping(
                            map,
                            mapping_start,
                            mapping_indent,
                            mapping_line,
                            mapping_tab_after_indent,
                            false,
                        );

                        if (implicit_key_anchors.mapping_anchor) |mapping_anchor| {
                            try self.anchors.put(mapping_anchor.slice(self.input), parent_map);
                        }

                        break :node parent_map;
                    }
                    break :node map;
                },

                .mapping_key => {
                    if (!opts.flow_pair_allowed) {
                        switch (self.context.get()) {
                            .flow_in, .flow_key => return unexpectedToken(),
                            .block_out, .block_in => {},
                        }
                    }

                    const mapping_start = self.token.start;
                    const mapping_indent = self.token.indent;
                    const mapping_line = self.token.line;
                    const mapping_tab_after_indent = self.token.tab_after_indent;

                    const key = key: {
                        try self.block_indents.push(mapping_indent);
                        defer self.block_indents.pop();
                        switch (self.context.get()) {
                            .block_out, .block_in => try self.scan(.{
                                .additional_parent_indent = mapping_indent.add(1),
                                .block_indented = true,
                            }),
                            .flow_in, .flow_key => try self.scan(.{}),
                        }
                        break :key try self.parseBlockIndented(
                            mapping_indent,
                            mapping_line,
                            mapping_start,
                            .explicit_mapping_key,
                        );
                    };

                    if (opts.current_mapping_indent) |current_mapping_indent| {
                        if (current_mapping_indent == mapping_indent) {
                            return key;
                        }
                    }

                    break :node try self.parseBlockMapping(
                        key,
                        mapping_start,
                        mapping_indent,
                        mapping_line,
                        mapping_tab_after_indent,
                        true,
                    );
                },
                .mapping_value => {
                    if (self.context.get() == .flow_key) {
                        break :node .init(E.Null, .{}, self.token.start.loc());
                    }
                    if (!opts.flow_pair_allowed and self.context.get() == .flow_in) {
                        break :node .init(E.Null, .{}, self.token.start.loc());
                    }
                    if (opts.current_mapping_indent) |current_mapping_indent| {
                        if (current_mapping_indent == self.token.indent) {
                            break :node .init(E.Null, .{}, self.token.start.loc());
                        }
                    }

                    const mapping_value_line = self.token.line;
                    var key_anchor: ?Token(enc) = null;
                    if (node_props.has_mapping_anchor) |mapping_anchor| {
                        const inner_anchor = node_props.has_anchor orelse return error.MultipleAnchors;
                        if (inner_anchor.line != mapping_value_line) {
                            return error.MultipleAnchors;
                        }
                        key_anchor = inner_anchor;
                        node_props.has_anchor = mapping_anchor;
                        node_props.has_mapping_anchor = null;
                    } else if (node_props.has_anchor) |anchor| {
                        if (anchor.line == mapping_value_line) {
                            key_anchor = anchor;
                            node_props.has_anchor = null;
                        }
                    }

                    var key_tag: NodeTag = .none;
                    if (node_props.has_mapping_tag) |mapping_tag| {
                        const inner_tag = node_props.has_tag orelse return error.MultipleTags;
                        if (inner_tag.line != mapping_value_line) {
                            return error.MultipleTags;
                        }
                        key_tag = inner_tag.data.tag;
                        node_props.has_tag = mapping_tag;
                        node_props.has_mapping_tag = null;
                    } else if (node_props.has_tag) |tag| {
                        if (tag.line == mapping_value_line) {
                            key_tag = tag.data.tag;
                            node_props.has_tag = null;
                        }
                    }

                    const first_key = key_tag.resolveNull(self.token.start.loc());
                    const mapping_tab_after_indent = self.token.tab_after_indent;
                    if (key_anchor) |anchor| {
                        try self.anchors.put(anchor.data.anchor.slice(self.input), first_key);
                    }
                    break :node try self.parseBlockMapping(
                        first_key,
                        self.token.start,
                        self.token.indent,
                        self.token.line,
                        mapping_tab_after_indent,
                        false,
                    );
                },
                .scalar => |scalar| {
                    const scalar_start = self.token.start;
                    const scalar_indent = self.token.indent;
                    const scalar_line = self.token.line;
                    const scalar_tab_after_indent = self.token.tab_after_indent;

                    try self.scan(.{ .tag = node_props.tag(), .outside_context = true });

                    if (self.token.data == .mapping_value) {
                        if (self.isExplicitMappingValue(opts, scalar_line)) {
                            break :node scalar.data.toExpr(scalar_start, self.input);
                        }

                        if (!opts.flow_pair_allowed and self.context.get() == .flow_in) {
                            break :node scalar.data.toExpr(scalar_start, self.input);
                        }

                        // this might be the start of a new object with an implicit key
                        //
                        // ```
                        // foo: bar        # yes
                        // ---
                        // {foo: bar}      # no (1)
                        // ---
                        // [foo: bar]      # yes (but can't have more than one prop) (2)
                        // ---
                        // - foo: bar      # yes
                        // ---
                        // [hi]: 123       # yes
                        // ---
                        // one: two        # first property is
                        // three: four     # no, this is another prop in the same object (3)
                        // ---
                        // one:            # yes
                        //   two: three    # and yes (nested object)
                        // ```
                        if (opts.current_mapping_indent) |current_mapping_indent| {
                            if (current_mapping_indent == scalar_indent) {
                                try self.rejectTabAsIndentation(scalar_tab_after_indent);
                                // 3
                                break :node scalar.data.toExpr(scalar_start, self.input);
                            }
                        }

                        switch (self.context.get()) {
                            .flow_key => {
                                // 1
                                break :node scalar.data.toExpr(scalar_start, self.input);
                            },
                            .flow_in,
                            .block_out,
                            .block_in,
                            => {
                                if (scalar_line != self.token.line and !opts.explicit_mapping_key) {
                                    return error.MultilineImplicitKey;
                                }
                            },
                        }

                        const implicit_key = scalar.data.toExpr(scalar_start, self.input);

                        const implicit_key_anchors = try node_props.implicitKeyAnchors(scalar_line);

                        if (implicit_key_anchors.key_anchor) |key_anchor| {
                            try self.anchors.put(key_anchor.slice(self.input), implicit_key);
                        }

                        const mapping = try self.parseBlockMapping(
                            implicit_key,
                            scalar_start,
                            scalar_indent,
                            scalar_line,
                            scalar_tab_after_indent,
                            false,
                        );

                        if (implicit_key_anchors.mapping_anchor) |mapping_anchor| {
                            try self.anchors.put(mapping_anchor.slice(self.input), mapping);
                        }

                        return mapping;
                    }

                    break :node scalar.data.toExpr(scalar_start, self.input);
                },
                .directive => {
                    return unexpectedToken();
                },
                .reserved => {
                    return unexpectedToken();
                },
            };
            return self.finishNodeProperties(node_props, node);
        }

        fn next(self: *const @This()) enc.unit() {
            const pos = self.pos;
            if (pos.isLessThan(self.input.len)) {
                return self.input[pos.cast()];
            }
            return 0;
        }

        fn foldLines(self: *@This()) usize {
            var total: usize = 0;
            return next: switch (self.next()) {
                '\r' => {
                    if (self.peek(1) == '\n') {
                        self.inc(1);
                    }

                    continue :next '\n';
                },
                '\n' => {
                    total += 1;
                    self.newline();
                    self.inc(1);
                    continue :next self.next();
                },
                ' ' => {
                    var indent: Indent = .from(1);
                    self.inc(1);
                    while (self.next() == ' ') {
                        self.inc(1);
                        indent.inc(1);
                    }

                    self.line_indent = indent;

                    if (self.next() == '\t') self.tab_after_indent = true;
                    self.skipSWhite();
                    continue :next self.next();
                },
                '\t' => {
                    // there's no indentation, but we still skip
                    // the whitespace
                    self.tab_after_indent = true;
                    self.inc(1);
                    self.skipSWhite();
                    continue :next self.next();
                },
                else => total,
            };
        }

        const ScanPlainScalarError = OOM || error{
            UnexpectedCharacter,
        };

        fn scanPlainScalar(self: *@This(), opts: ScanOptions) ScanPlainScalarError!Token(enc) {
            const ScalarResolverCtx = struct {
                str_builder: String.Builder,

                resolved: bool = false,
                scalar: ?NodeScalar,
                tag: NodeTag,

                parser: *Parser(enc),

                resolved_scalar_len: usize = 0,

                start: Pos,
                line: Line,
                line_indent: Indent,
                multiline: bool = false,

                pub fn done(ctx: *@This()) Token(enc) {
                    const scalar: Token(enc).Scalar = scalar: {
                        var scalar_str = ctx.str_builder.done();

                        if (ctx.scalar) |scalar| {
                            if (scalar_str.len() == ctx.resolved_scalar_len) {
                                scalar_str.deinit();
                                break :scalar .{
                                    .multiline = ctx.multiline,
                                    .data = scalar,
                                };
                            }
                            // the first characters resolved to something
                            // but there were more characters afterwards
                        }

                        break :scalar .{
                            .multiline = ctx.multiline,
                            .data = .{ .string = scalar_str },
                        };
                    };

                    return .scalar(.{
                        .start = ctx.start,
                        .indent = ctx.line_indent,
                        .line = ctx.line,
                        .resolved = scalar,
                    });
                }

                pub fn checkAppend(ctx: *@This()) void {
                    if (ctx.str_builder.len() == 0) {
                        ctx.line_indent = ctx.parser.line_indent;
                        ctx.line = ctx.parser.line;
                    } else if (ctx.line != ctx.parser.line) {
                        ctx.multiline = true;
                    }
                }

                pub fn appendSource(ctx: *@This(), unit: enc.unit(), pos: Pos) OOM!void {
                    ctx.checkAppend();
                    try ctx.str_builder.appendSource(unit, pos);
                }

                pub fn appendSourceWhitespace(ctx: *@This(), unit: enc.unit(), pos: Pos) OOM!void {
                    try ctx.str_builder.appendSourceWhitespace(unit, pos);
                }

                pub fn appendSourceSlice(ctx: *@This(), off: Pos, end: Pos) OOM!void {
                    ctx.checkAppend();
                    try ctx.str_builder.appendSourceSlice(off, end);
                }

                // may or may not contain whitespace
                pub fn appendUnknownSourceSlice(ctx: *@This(), off: Pos, end: Pos) OOM!void {
                    for (off.cast()..end.cast()) |_pos| {
                        const pos: Pos = .from(_pos);
                        const unit = ctx.parser.input[pos.cast()];
                        switch (unit) {
                            ' ',
                            '\t',
                            '\r',
                            '\n',
                            => {
                                try ctx.str_builder.appendSourceWhitespace(unit, pos);
                            },
                            else => {
                                ctx.checkAppend();
                                try ctx.str_builder.appendSource(unit, pos);
                            },
                        }
                    }
                }

                pub fn append(ctx: *@This(), unit: enc.unit()) OOM!void {
                    ctx.checkAppend();
                    try ctx.str_builder.append(unit);
                }

                pub fn appendWhitespace(ctx: *@This(), unit: enc.unit()) OOM!void {
                    try ctx.str_builder.appendWhitespace(unit);
                }

                pub fn appendSlice(ctx: *@This(), str: []const enc.unit()) OOM!void {
                    ctx.checkAppend();
                    try ctx.str_builder.appendSlice(str);
                }

                pub fn appendNTimes(ctx: *@This(), unit: enc.unit(), n: usize) OOM!void {
                    if (n == 0) {
                        return;
                    }
                    ctx.checkAppend();
                    try ctx.str_builder.appendNTimes(unit, n);
                }

                pub fn appendWhitespaceNTimes(ctx: *@This(), unit: enc.unit(), n: usize) OOM!void {
                    if (n == 0) {
                        return;
                    }

                    try ctx.str_builder.appendWhitespaceNTimes(unit, n);
                }

                const Keywords = enum {
                    null,
                    Null,
                    NULL,
                    @"~",

                    true,
                    True,
                    TRUE,
                    yes,
                    Yes,
                    YES,
                    on,
                    On,
                    ON,

                    false,
                    False,
                    FALSE,
                    no,
                    No,
                    NO,
                    off,
                    Off,
                    OFF,
                };

                const ResolveError = OOM;

                pub fn resolve(
                    ctx: *@This(),
                    scalar: NodeScalar,
                    off: Pos,
                    text: []const enc.unit(),
                ) ResolveError!void {
                    try ctx.str_builder.appendExpectedSourceSlice(off, off.add(text.len), text);

                    ctx.resolved = true;

                    switch (ctx.tag) {
                        .none => {
                            ctx.resolved_scalar_len = ctx.str_builder.len();
                            ctx.scalar = scalar;
                        },
                        .non_specific => {
                            // always becomes string
                        },
                        .bool => {
                            if (scalar == .boolean) {
                                ctx.resolved_scalar_len = ctx.str_builder.len();
                                ctx.scalar = scalar;
                            }
                        },
                        .int => {
                            if (scalar == .number) {
                                ctx.resolved_scalar_len = ctx.str_builder.len();
                                ctx.scalar = scalar;
                            }
                        },
                        .float => {
                            if (scalar == .number) {
                                ctx.resolved_scalar_len = ctx.str_builder.len();
                                ctx.scalar = scalar;
                            }
                        },
                        .null => {
                            if (scalar == .null) {
                                ctx.resolved_scalar_len = ctx.str_builder.len();
                                ctx.scalar = scalar;
                            }
                        },
                        .str => {
                            // always becomes string
                        },

                        .verbatim,
                        .unknown,
                        => {
                            // also always becomes a string
                        },
                    }
                }

                fn isCoreSchemaNumber(text: []const enc.unit(), has_sign: bool) bool {
                    if (text.len == 0) return false;

                    if (!has_sign and text.len > 2 and text[0] == '0') {
                        const digits = text[2..];
                        switch (text[1]) {
                            'x' => {
                                for (digits) |c| switch (c) {
                                    '0'...'9', 'a'...'f', 'A'...'F' => {},
                                    else => return false,
                                };
                                return true;
                            },
                            'o' => {
                                for (digits) |c| switch (c) {
                                    '0'...'7' => {},
                                    else => return false,
                                };
                                return true;
                            },
                            else => {},
                        }
                    }

                    var i: usize = 0;
                    while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) {}
                    var has_digits = i != 0;

                    if (i < text.len and text[i] == '.') {
                        i += 1;
                        const fraction_start = i;
                        while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) {}
                        has_digits = has_digits or i != fraction_start;
                    }

                    if (!has_digits) return false;

                    if (i < text.len and (text[i] == 'e' or text[i] == 'E')) {
                        i += 1;
                        if (i < text.len and (text[i] == '+' or text[i] == '-')) i += 1;

                        const exponent_start = i;
                        while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) {}
                        if (i == exponent_start) return false;
                    }

                    return i == text.len;
                }

                pub fn tryResolveNumber(
                    ctx: *@This(),
                    parser: *Parser(enc),
                    first_char: enum { positive, negative, dot, other },
                ) ResolveError!void {
                    const nan = std.math.nan(f64);
                    const inf = std.math.inf(f64);

                    switch (first_char) {
                        .dot => {
                            switch (parser.next()) {
                                'n' => {
                                    const n_start = parser.pos;
                                    parser.inc(1);
                                    if (parser.remainStartsWith("an")) {
                                        try ctx.resolve(.{ .number = nan }, n_start, "nan");
                                        parser.inc(2);
                                        return;
                                    }
                                    try ctx.appendSource('n', n_start);
                                    return;
                                },
                                'N' => {
                                    const n_start = parser.pos;
                                    parser.inc(1);
                                    if (parser.remainStartsWith("aN")) {
                                        try ctx.resolve(.{ .number = nan }, n_start, "NaN");
                                        parser.inc(2);
                                        return;
                                    }
                                    if (parser.remainStartsWith("AN")) {
                                        try ctx.resolve(.{ .number = nan }, n_start, "NAN");
                                        parser.inc(2);
                                        return;
                                    }
                                    try ctx.appendSource('N', n_start);
                                    return;
                                },
                                'i' => {
                                    const i_start = parser.pos;
                                    parser.inc(1);
                                    if (parser.remainStartsWith("nf")) {
                                        try ctx.resolve(.{ .number = inf }, i_start, "inf");
                                        parser.inc(2);
                                        return;
                                    }
                                    try ctx.appendSource('i', i_start);
                                    return;
                                },
                                'I' => {
                                    const i_start = parser.pos;
                                    parser.inc(1);
                                    if (parser.remainStartsWith("nf")) {
                                        try ctx.resolve(.{ .number = inf }, i_start, "Inf");
                                        parser.inc(2);
                                        return;
                                    }
                                    if (parser.remainStartsWith("NF")) {
                                        try ctx.resolve(.{ .number = inf }, i_start, "INF");
                                        parser.inc(2);
                                        return;
                                    }
                                    try ctx.appendSource('I', i_start);
                                    return;
                                },
                                else => {},
                            }
                        },
                        .negative, .positive => {
                            if (parser.next() == '.' and parser.peek(1) == 'i' or parser.peek(1) == 'I') {
                                try ctx.appendSource('.', parser.pos);
                                parser.inc(1);
                                switch (parser.next()) {
                                    'i' => {
                                        const i_start = parser.pos;
                                        parser.inc(1);
                                        if (parser.remainStartsWith("nf")) {
                                            try ctx.resolve(
                                                .{ .number = if (first_char == .negative) -inf else inf },
                                                i_start,
                                                "inf",
                                            );
                                            parser.inc(2);
                                            return;
                                        }
                                        try ctx.appendSource('i', i_start);
                                        return;
                                    },
                                    'I' => {
                                        const i_start = parser.pos;
                                        parser.inc(1);
                                        if (parser.remainStartsWith("nf")) {
                                            try ctx.resolve(
                                                .{ .number = if (first_char == .negative) -inf else inf },
                                                i_start,
                                                "Inf",
                                            );
                                            parser.inc(2);
                                            return;
                                        }
                                        if (parser.remainStartsWith("NF")) {
                                            try ctx.resolve(
                                                .{ .number = if (first_char == .negative) -inf else inf },
                                                i_start,
                                                "INF",
                                            );
                                            parser.inc(2);
                                            return;
                                        }
                                        try ctx.appendSource('I', i_start);
                                        return;
                                    },
                                    else => {
                                        return;
                                    },
                                }
                            }
                        },
                        .other => {},
                    }

                    const start = parser.pos;

                    if (first_char != .negative and first_char != .positive) {
                        parser.inc(1);
                    }

                    const end, const valid = end: switch (parser.next()) {

                        // can only be valid if it ends on:
                        // - ' '
                        // - '\t'
                        // - eof
                        // - '\n'
                        // - '\r'
                        // - ':'
                        ' ',
                        '\t',
                        0,
                        '\n',
                        '\r',
                        ':',
                        => .{ parser.pos, true },

                        ',',
                        ']',
                        '}',
                        => {
                            switch (parser.context.get()) {
                                // it's valid for ',' ']' '}' to end the scalar
                                // in flow context
                                .flow_in,
                                .flow_key,
                                => break :end .{ parser.pos, true },

                                .block_in,
                                .block_out,
                                => break :end .{ parser.pos, false },
                            }
                        },

                        '0'...'9',
                        'a'...'f',
                        'A'...'F',
                        'x',
                        'o',
                        '.',
                        '+',
                        '-',
                        => {
                            parser.inc(1);
                            continue :end parser.next();
                        },
                        else => .{ parser.pos, false },
                    };

                    try ctx.appendUnknownSourceSlice(start, end);

                    if (!valid) {
                        return;
                    }

                    const number = parser.slice(start, end);
                    const has_sign = first_char == .negative or first_char == .positive;
                    if (!isCoreSchemaNumber(number, has_sign)) {
                        return;
                    }

                    var scalar: NodeScalar = scalar: {
                        const prefixed_integer = !has_sign and number.len > 2 and number[0] == '0' and
                            (number[1] == 'x' or number[1] == 'o');
                        if (prefixed_integer) {
                            const unsigned = std.fmt.parseUnsigned(u64, number, 0) catch {
                                return;
                            };
                            break :scalar .{ .number = @floatFromInt(unsigned) };
                        }
                        const float = bun.jsc.wtf.parseDouble(number) catch {
                            return;
                        };

                        break :scalar .{ .number = float };
                    };

                    ctx.resolved = true;

                    switch (ctx.tag) {
                        .none,
                        .float,
                        .int,
                        => {
                            ctx.resolved_scalar_len = ctx.str_builder.len();
                            if (first_char == .negative) {
                                scalar.number = -scalar.number;
                            }
                            ctx.scalar = scalar;
                        },
                        else => {},
                    }
                }
            };

            var ctx: ScalarResolverCtx = .{
                .str_builder = self.stringBuilder(),
                .parser = self,
                .scalar = null,
                .tag = opts.tag,
                .start = self.pos,
                .line = self.line,
                .line_indent = self.line_indent,
            };

            next: switch (self.next()) {
                0 => {
                    return ctx.done();
                },

                '-' => {
                    if (self.isDocumentIndicator("---")) {
                        return ctx.done();
                    }

                    if (!ctx.resolved and ctx.str_builder.len() == 0) {
                        try ctx.appendSource('-', self.pos);
                        self.inc(1);
                        try ctx.tryResolveNumber(self, .negative);
                        continue :next self.next();
                    }

                    try ctx.appendSource('-', self.pos);
                    self.inc(1);
                    continue :next self.next();
                },

                '.' => {
                    if (self.isDocumentIndicator("...")) {
                        return ctx.done();
                    }

                    if (!ctx.resolved and ctx.str_builder.len() == 0) {
                        switch (self.peek(1)) {
                            'n',
                            'N',
                            'i',
                            'I',
                            => {
                                try ctx.appendSource('.', self.pos);
                                self.inc(1);
                                try ctx.tryResolveNumber(self, .dot);
                                continue :next self.next();
                            },

                            else => {
                                try ctx.tryResolveNumber(self, .other);
                                continue :next self.next();
                            },
                        }
                    }

                    try ctx.appendSource('.', self.pos);
                    self.inc(1);
                    continue :next self.next();
                },

                ':' => {
                    if (self.isSWhiteOrBCharOrEofAt(1)) {
                        return ctx.done();
                    }

                    switch (self.context.get()) {
                        .block_out,
                        .block_in,
                        => {},
                        .flow_in, .flow_key => {
                            switch (self.peek(1)) {
                                ',',
                                '[',
                                ']',
                                '{',
                                '}',
                                => {
                                    return ctx.done();
                                },
                                else => {},
                            }
                        },
                    }

                    try ctx.appendSource(':', self.pos);
                    self.inc(1);
                    continue :next self.next();
                },

                '#' => {
                    const prev = self.input[self.pos.sub(1).cast()];
                    if (self.pos == .zero or switch (prev) {
                        ' ',
                        '\t',
                        '\r',
                        '\n',
                        => true,
                        else => false,
                    }) {
                        return ctx.done();
                    }

                    try ctx.appendSource('#', self.pos);
                    self.inc(1);
                    continue :next self.next();
                },

                ',',
                '[',
                ']',
                '{',
                '}',
                => |c| {
                    switch (self.context.get()) {
                        .block_in,
                        .block_out,
                        => {},

                        .flow_in,
                        .flow_key,
                        => {
                            return ctx.done();
                        },
                    }

                    try ctx.appendSource(c, self.pos);
                    self.inc(1);
                    continue :next self.next();
                },

                ' ',
                '\t',
                => |c| {
                    try ctx.appendSourceWhitespace(c, self.pos);
                    self.inc(1);
                    continue :next self.next();
                },

                '\r' => {
                    if (self.peek(1) == '\n') {
                        self.inc(1);
                    }

                    continue :next '\n';
                },

                '\n' => {
                    self.newline();
                    self.inc(1);

                    const lines = self.foldLines();

                    if (self.block_indents.get()) |block_indent| {
                        switch (self.line_indent.cmp(block_indent)) {
                            .gt => {
                                // continue (whitespace already stripped)
                            },
                            .lt, .eq => {
                                // end here. this it the start of a new value.
                                return ctx.done();
                            },
                        }
                    }

                    // clear the leading whitespace before the newline.
                    ctx.parser.whitespace_buf.clearRetainingCapacity();

                    if (lines == 0 and !self.isEof()) {
                        try ctx.appendWhitespace(' ');
                    }

                    try ctx.appendWhitespaceNTimes('\n', lines);

                    continue :next self.next();
                },

                else => |c| {
                    if (ctx.resolved or ctx.str_builder.len() != 0) {
                        const start = self.pos;
                        self.inc(1);
                        try ctx.appendSource(c, start);
                        continue :next self.next();
                    }

                    // first non-whitespace

                    // TODO: make more better
                    switch (c) {
                        'n' => {
                            const n_start = self.pos;
                            self.inc(1);
                            if (self.remainStartsWith("ull")) {
                                try ctx.resolve(.null, n_start, "null");
                                self.inc(3);
                                continue :next self.next();
                            }
                            try ctx.appendSource(c, n_start);
                            continue :next self.next();
                        },
                        'N' => {
                            const n_start = self.pos;
                            self.inc(1);
                            if (self.remainStartsWith("ull")) {
                                try ctx.resolve(.null, n_start, "Null");
                                self.inc(3);
                                continue :next self.next();
                            }
                            if (self.remainStartsWith("ULL")) {
                                try ctx.resolve(.null, n_start, "NULL");
                                self.inc(3);
                                continue :next self.next();
                            }
                            try ctx.appendSource(c, n_start);
                            continue :next self.next();
                        },
                        '~' => {
                            const start = self.pos;
                            self.inc(1);
                            try ctx.resolve(.null, start, "~");
                            continue :next self.next();
                        },
                        't' => {
                            const t_start = self.pos;
                            self.inc(1);
                            if (self.remainStartsWith("rue")) {
                                try ctx.resolve(.{ .boolean = true }, t_start, "true");
                                self.inc(3);
                                continue :next self.next();
                            }
                            try ctx.appendSource(c, t_start);
                            continue :next self.next();
                        },
                        'T' => {
                            const t_start = self.pos;
                            self.inc(1);
                            if (self.remainStartsWith("rue")) {
                                try ctx.resolve(.{ .boolean = true }, t_start, "True");
                                self.inc(3);
                                continue :next self.next();
                            }
                            if (self.remainStartsWith("RUE")) {
                                try ctx.resolve(.{ .boolean = true }, t_start, "TRUE");
                                self.inc(3);
                                continue :next self.next();
                            }
                            try ctx.appendSource(c, t_start);
                            continue :next self.next();
                        },
                        'f' => {
                            const f_start = self.pos;
                            self.inc(1);
                            if (self.remainStartsWith("alse")) {
                                try ctx.resolve(.{ .boolean = false }, f_start, "false");
                                self.inc(4);
                                continue :next self.next();
                            }
                            try ctx.appendSource(c, f_start);
                            continue :next self.next();
                        },
                        'F' => {
                            const f_start = self.pos;
                            self.inc(1);
                            if (self.remainStartsWith("alse")) {
                                try ctx.resolve(.{ .boolean = false }, f_start, "False");
                                self.inc(4);
                                continue :next self.next();
                            }
                            if (self.remainStartsWith("ALSE")) {
                                try ctx.resolve(.{ .boolean = false }, f_start, "FALSE");
                                self.inc(4);
                                continue :next self.next();
                            }
                            try ctx.appendSource(c, f_start);
                            continue :next self.next();
                        },

                        '-' => {
                            try ctx.appendSource('-', self.pos);
                            self.inc(1);
                            try ctx.tryResolveNumber(self, .negative);
                            continue :next self.next();
                        },

                        '+' => {
                            try ctx.appendSource('+', self.pos);
                            self.inc(1);
                            try ctx.tryResolveNumber(self, .positive);
                            continue :next self.next();
                        },

                        '0'...'9' => {
                            try ctx.tryResolveNumber(self, .other);
                            continue :next self.next();
                        },

                        '.' => {
                            switch (self.peek(1)) {
                                'n',
                                'N',
                                'i',
                                'I',
                                => {
                                    try ctx.appendSource('.', self.pos);
                                    self.inc(1);
                                    try ctx.tryResolveNumber(self, .dot);
                                    continue :next self.next();
                                },

                                else => {
                                    try ctx.tryResolveNumber(self, .other);
                                    continue :next self.next();
                                },
                            }
                        },

                        else => {
                            const start = self.pos;
                            self.inc(1);
                            try ctx.appendSource(c, start);
                            continue :next self.next();
                        },
                    }
                },
            }
        }

        const ScanBlockHeaderError = error{UnexpectedCharacter};
        const ScanBlockHeaderResult = struct { Indent.Indicator, Chomp };

        // positions parser at the first line break, or eof
        fn scanBlockHeader(self: *@This()) ScanBlockHeaderError!ScanBlockHeaderResult {
            // consume c-b-block-header

            var indent_indicator: ?Indent.Indicator = null;
            var chomp: ?Chomp = null;

            next: switch (self.next()) {
                0 => {
                    return .{
                        indent_indicator orelse .default,
                        chomp orelse .default,
                    };
                },
                '1'...'9' => |digit| {
                    if (indent_indicator != null) {
                        return error.UnexpectedCharacter;
                    }

                    indent_indicator = @fromBackingInt(@intCast(digit - '0'));
                    self.inc(1);
                    continue :next self.next();
                },
                '-' => {
                    if (chomp != null) {
                        return error.UnexpectedCharacter;
                    }

                    chomp = .strip;
                    self.inc(1);
                    continue :next self.next();
                },
                '+' => {
                    if (chomp != null) {
                        return error.UnexpectedCharacter;
                    }

                    chomp = .keep;
                    self.inc(1);
                    continue :next self.next();
                },

                ' ',
                '\t',
                => {
                    self.inc(1);

                    self.skipSWhite();

                    if (self.next() == '#') {
                        self.inc(1);
                        while (!self.isBCharOrEof()) {
                            self.inc(1);
                        }
                    }

                    continue :next self.next();
                },

                '\r' => {
                    if (self.peek(1) == '\n') {
                        self.inc(1);
                    }
                    continue :next '\n';
                },

                '\n' => {

                    // the first newline is always excluded from a literal
                    self.inc(1);

                    if (self.next() == '\t') {
                        // tab for indentation
                        return error.UnexpectedCharacter;
                    }

                    return .{
                        indent_indicator orelse .default,
                        chomp orelse .default,
                    };
                },

                else => {
                    return error.UnexpectedCharacter;
                },
            }
        }

        const ScanLiteralScalarError = OOM || error{
            UnexpectedCharacter,
            InvalidIndentation,
        };

        fn scanLiteralScalarBody(self: *@This(), indent_indicator: Indent.Indicator, chomp: Chomp, folded: bool, start: Pos, line: Line, token_indent: Indent) ScanLiteralScalarError!Token(enc) {
            const LiteralScalarCtx = struct {
                chomp: Chomp,
                leading_newlines: usize,
                text: std.array_list.Managed(enc.unit()),
                start: Pos,
                token_indent: Indent,
                content_indent: Indent,
                previous_indent: ?Indent,
                max_leading_indent: Indent,
                unterminated_line: bool,
                line: Line,
                folded: bool,

                pub fn done(ctx: *@This(), eof_break: bool) OOM!Token(enc) {
                    switch (ctx.chomp) {
                        .keep => try ctx.text.appendNTimes('\n', ctx.leading_newlines + @as(usize, @intFromBool(eof_break))),
                        .clip => {
                            if (ctx.text.items.len != 0) {
                                try ctx.text.append('\n');
                            }
                        },
                        .strip => {
                            // no trailing newlines
                        },
                    }

                    return .scalar(.{
                        .start = ctx.start,
                        .indent = ctx.token_indent,
                        .line = ctx.line,
                        .resolved = .{
                            .data = .{ .string = .{ .list = ctx.text } },
                            .multiline = true,
                        },
                    });
                }

                const AppendError = OOM || error{UnexpectedCharacter};

                pub fn append(ctx: *@This(), c: enc.unit(), current_indent: Indent) AppendError!void {
                    if (ctx.text.items.len == 0 and ctx.content_indent.isLessThan(ctx.max_leading_indent)) {
                        return error.UnexpectedCharacter;
                    }

                    const adjacent_normal_lines = if (ctx.previous_indent) |previous_indent|
                        previous_indent == ctx.content_indent and current_indent == ctx.content_indent
                    else
                        false;

                    try ctx.text.ensureUnusedCapacity(ctx.leading_newlines + 1);
                    // A folded break becomes a space only when neither adjacent
                    // content line is more-indented.
                    if (ctx.folded and adjacent_normal_lines) {
                        if (ctx.leading_newlines == 1) {
                            ctx.text.appendAssumeCapacity(' ');
                        } else if (ctx.leading_newlines > 1) {
                            ctx.text.appendNTimesAssumeCapacity('\n', ctx.leading_newlines - 1);
                        }
                    } else {
                        ctx.text.appendNTimesAssumeCapacity('\n', ctx.leading_newlines);
                    }
                    ctx.text.appendAssumeCapacity(c);
                    ctx.leading_newlines = 0;
                }
            };

            var ctx: LiteralScalarCtx = .{
                .chomp = chomp,
                .text = .init(self.allocator),
                .folded = folded,
                .start = start,
                .token_indent = token_indent,
                .line = line,

                .leading_newlines = 0,
                .content_indent = .none,
                .previous_indent = null,
                .max_leading_indent = .none,
                .unterminated_line = false,
            };

            var body_started = false;
            const first = if (indent_indicator == .auto) auto: {
                ctx.content_indent, const c = auto_indent: switch (self.next()) {
                    0 => {
                        if (body_started) {
                            break :auto_indent .{ self.line_indent, 0 };
                        }
                        return ctx.done(false);
                    },

                    '\r' => {
                        if (self.peek(1) == '\n') {
                            self.inc(1);
                        }
                        continue :auto_indent '\n';
                    },
                    '\n' => {
                        body_started = true;
                        ctx.unterminated_line = false;
                        self.newline();
                        self.inc(1);
                        if (self.next() == '\t') {
                            // tab for indentation
                            return error.UnexpectedCharacter;
                        }
                        ctx.leading_newlines += 1;
                        continue :auto_indent self.next();
                    },

                    ' ' => {
                        body_started = true;
                        ctx.unterminated_line = true;
                        var indent: Indent = .from(1);
                        self.inc(1);
                        while (self.next() == ' ') {
                            indent.inc(1);
                            self.inc(1);
                        }

                        if (ctx.max_leading_indent.isLessThan(indent)) {
                            ctx.max_leading_indent = indent;
                        }

                        self.line_indent = indent;

                        continue :auto_indent self.next();
                    },

                    else => |c| {
                        body_started = true;
                        ctx.unterminated_line = true;
                        break :auto_indent .{ self.line_indent, c };
                    },
                };
                break :auto c;
            } else explicit: {
                const parent_indent = self.block_indents.get() orelse .none;
                ctx.content_indent = parent_indent.add(@as(usize, indent_indicator.get()));
                self.line_indent = .none;

                const c = explicit_indent: switch (self.next()) {
                    0 => {
                        if (body_started) {
                            break :explicit_indent 0;
                        }
                        return ctx.done(false);
                    },

                    '\r' => {
                        if (self.peek(1) == '\n') {
                            self.inc(1);
                        }
                        continue :explicit_indent '\n';
                    },
                    '\n' => {
                        body_started = true;
                        ctx.unterminated_line = false;
                        self.newline();
                        self.inc(1);
                        if (self.next() == '\t') {
                            // tab for indentation
                            return error.UnexpectedCharacter;
                        }
                        ctx.leading_newlines += 1;
                        continue :explicit_indent self.next();
                    },

                    ' ' => {
                        body_started = true;
                        ctx.unterminated_line = true;
                        var indent: Indent = .none;
                        while (self.next() == ' ') {
                            indent.inc(1);
                            if (ctx.content_indent.isLessThan(indent)) {
                                try ctx.append(' ', indent);
                            }
                            self.inc(1);
                        }
                        self.line_indent = indent;
                        continue :explicit_indent self.next();
                    },

                    else => |char| {
                        body_started = true;
                        ctx.unterminated_line = true;
                        break :explicit_indent char;
                    },
                };
                break :explicit c;
            };

            if (first == '\t') {
                self.tab_after_indent = true;
            }

            next: switch (first) {
                0 => {
                    const eof_break = ctx.unterminated_line and (ctx.leading_newlines == 0 or ctx.text.items.len == 0);
                    return ctx.done(eof_break);
                },

                '\r' => {
                    if (self.peek(1) == '\n') {
                        self.inc(1);
                    }
                    continue :next '\n';
                },
                '\n' => {
                    if (ctx.leading_newlines == 0 and ctx.text.items.len != 0) {
                        ctx.previous_indent = self.line_indent;
                    }
                    ctx.leading_newlines += 1;
                    ctx.unterminated_line = false;
                    self.newline();
                    self.inc(1);
                    newlines: switch (self.next()) {
                        '\r' => {
                            if (self.peek(1) == '\n') {
                                self.inc(1);
                            }
                            continue :newlines '\n';
                        },
                        '\n' => {
                            ctx.leading_newlines += 1;
                            self.newline();
                            self.inc(1);
                            if (self.next() == '\t') self.tab_after_indent = true;
                            continue :newlines self.next();
                        },
                        ' ' => {
                            ctx.unterminated_line = true;
                            var indent: Indent = .from(0);
                            while (self.next() == ' ') {
                                indent.inc(1);
                                if (ctx.content_indent.isLessThan(indent)) {
                                    try ctx.append(' ', indent);
                                }
                                self.inc(1);
                            }

                            if (self.next() == '\t') {
                                self.tab_after_indent = true;
                            }

                            self.line_indent = indent;

                            continue :next self.next();
                        },
                        else => |c| {
                            if (c == '\t') self.tab_after_indent = true;
                            continue :next c;
                        },
                    }
                },

                else => |c| {
                    const document_indicator = switch (c) {
                        '-' => self.isDocumentIndicator("---"),
                        '.' => self.isDocumentIndicator("..."),
                        else => false,
                    };
                    if (document_indicator) return ctx.done(false);

                    if (self.block_indents.get()) |block_indent| {
                        if (self.line_indent.isLessThanOrEqual(block_indent)) {
                            if (c == '\t') return error.InvalidIndentation;
                            return ctx.done(false);
                        }
                    }
                    if (self.line_indent.isLessThan(ctx.content_indent)) {
                        return ctx.done(false);
                    }

                    if (c == '\t') self.line_indent.inc(1);

                    ctx.unterminated_line = true;
                    try ctx.append(c, self.line_indent);

                    self.inc(1);
                    continue :next self.next();
                },
            }
        }

        fn scanLiteralScalar(self: *@This()) ScanLiteralScalarError!Token(enc) {
            defer self.whitespace_buf.clearRetainingCapacity();

            const start = self.pos;
            const line = self.line;
            const token_indent = self.line_indent;

            const indent_indicator, const chomp = try self.scanBlockHeader();
            self.line_indent = .none;

            return self.scanLiteralScalarBody(indent_indicator, chomp, false, start, line, token_indent);
        }

        fn scanFoldedScalar(self: *@This()) ScanLiteralScalarError!Token(enc) {
            const start = self.pos;
            const line = self.line;
            const token_indent = self.line_indent;

            const indent_indicator, const chomp = try self.scanBlockHeader();
            self.line_indent = .none;

            return self.scanLiteralScalarBody(indent_indicator, chomp, true, start, line, token_indent);
        }

        const ScanSingleQuotedScalarError = OOM || error{
            UnexpectedCharacter,
            UnexpectedDocumentStart,
            UnexpectedDocumentEnd,
        };

        fn scanSingleQuotedScalar(self: *@This()) ScanSingleQuotedScalarError!Token(enc) {
            const start = self.pos;
            const scalar_line = self.line;
            const scalar_indent = self.line_indent;

            var text: std.array_list.Managed(enc.unit()) = .init(self.allocator);

            next: switch (self.next()) {
                0 => return error.UnexpectedCharacter,

                '.' => {
                    if (self.isDocumentIndicator("...")) return error.UnexpectedDocumentEnd;
                    try text.append('.');
                    self.inc(1);
                    continue :next self.next();
                },

                '-' => {
                    if (self.isDocumentIndicator("---")) return error.UnexpectedDocumentStart;
                    try text.append('-');
                    self.inc(1);
                    continue :next self.next();
                },

                '\r',
                '\n',
                => {
                    self.newline();
                    self.inc(1);
                    switch (self.foldLines()) {
                        0 => try text.append(' '),
                        else => |lines| try text.appendNTimes('\n', lines),
                    }
                    if (self.block_indents.get()) |block_indent| {
                        if (self.line_indent.isLessThanOrEqual(block_indent)) {
                            return error.UnexpectedCharacter;
                        }
                    }
                    continue :next self.next();
                },

                ' ',
                '\t',
                => {
                    const off = self.pos;
                    self.inc(1);
                    self.skipSWhite();
                    if (!self.isBChar()) {
                        try text.appendSlice(self.slice(off, self.pos));
                    }
                    continue :next self.next();
                },

                '\'' => {
                    self.inc(1);
                    if (self.next() == '\'') {
                        try text.append('\'');
                        self.inc(1);
                        continue :next self.next();
                    }

                    return .scalar(.{
                        .start = start,
                        .indent = scalar_indent,
                        .line = scalar_line,
                        .resolved = .{
                            // TODO: wrong!
                            .multiline = self.line != scalar_line,
                            .data = .{
                                .string = .{
                                    .list = text,
                                },
                            },
                        },
                    });
                },
                else => |c| {
                    try text.append(c);
                    self.inc(1);
                    continue :next self.next();
                },
            }
        }

        const ScanDoubleQuotedScalarError = OOM || error{
            UnexpectedCharacter,
            UnexpectedDocumentStart,
            UnexpectedDocumentEnd,
        };

        fn scanDoubleQuotedScalar(self: *@This()) ScanDoubleQuotedScalarError!Token(enc) {
            const start = self.pos;
            const scalar_line = self.line;
            const scalar_indent = self.line_indent;
            var text: std.array_list.Managed(enc.unit()) = .init(self.allocator);

            next: switch (self.next()) {
                0 => return error.UnexpectedCharacter,

                '.' => {
                    if (self.isDocumentIndicator("...")) return error.UnexpectedDocumentEnd;
                    try text.append('.');
                    self.inc(1);
                    continue :next self.next();
                },

                '-' => {
                    if (self.isDocumentIndicator("---")) return error.UnexpectedDocumentStart;
                    try text.append('-');
                    self.inc(1);
                    continue :next self.next();
                },

                '\r',
                '\n',
                => {
                    self.newline();
                    self.inc(1);
                    switch (self.foldLines()) {
                        0 => try text.append(' '),
                        else => |lines| try text.appendNTimes('\n', lines),
                    }

                    if (self.block_indents.get()) |block_indent| {
                        if (self.line_indent.isLessThanOrEqual(block_indent)) {
                            return error.UnexpectedCharacter;
                        }
                    }
                    continue :next self.next();
                },

                ' ',
                '\t',
                => {
                    const off = self.pos;
                    self.inc(1);
                    self.skipSWhite();
                    if (!self.isBChar()) {
                        try text.appendSlice(self.slice(off, self.pos));
                    }
                    continue :next self.next();
                },

                '"' => {
                    self.inc(1);
                    return .scalar(.{
                        .start = start,
                        .indent = scalar_indent,
                        .line = scalar_line,
                        .resolved = .{
                            // TODO: wrong!
                            .multiline = self.line != scalar_line,
                            .data = .{
                                .string = .{ .list = text },
                            },
                        },
                    });
                },

                '\\' => {
                    self.inc(1);
                    switch (self.next()) {
                        '\r',
                        '\n',
                        => {
                            self.newline();
                            self.inc(1);
                            const lines = self.foldLines();

                            if (self.block_indents.get()) |block_indent| {
                                if (self.line_indent.isLessThanOrEqual(block_indent)) {
                                    return error.UnexpectedCharacter;
                                }
                            }

                            try text.appendNTimes('\n', lines);
                            self.skipSWhite();
                            continue :next self.next();
                        },

                        // escaped whitespace
                        ' ' => try text.append(' '),
                        '\t' => try text.append('\t'),

                        '0' => try text.append(0),
                        'a' => try text.append(0x7),
                        'b' => try text.append(0x8),
                        't' => try text.append('\t'),
                        'n' => try text.append('\n'),
                        'v' => try text.append(0x0b),
                        'f' => try text.append(0xc),
                        'r' => try text.append(0xd),
                        'e' => try text.append(0x1b),
                        '"' => try text.append('"'),
                        '/' => try text.append('/'),
                        '\\' => try text.append('\\'),

                        'N' => switch (enc) {
                            .utf8 => try text.appendSlice(&.{ 0xc2, 0x85 }),
                            .utf16 => try text.append(0x0085),
                            .latin1 => return error.UnexpectedCharacter,
                        },
                        '_' => switch (enc) {
                            .utf8 => try text.appendSlice(&.{ 0xc2, 0xa0 }),
                            .utf16 => try text.append(0x00a0),
                            .latin1 => return error.UnexpectedCharacter,
                        },
                        'L' => switch (enc) {
                            .utf8 => try text.appendSlice(&.{ 0xe2, 0x80, 0xa8 }),
                            .utf16 => try text.append(0x2028),
                            .latin1 => return error.UnexpectedCharacter,
                        },
                        'P' => switch (enc) {
                            .utf8 => try text.appendSlice(&.{ 0xe2, 0x80, 0xa9 }),
                            .utf16 => try text.append(0x2029),
                            .latin1 => return error.UnexpectedCharacter,
                        },

                        'x' => try self.decodeHexCodePoint(.x, &text),
                        'u' => try self.decodeHexCodePoint(.u, &text),
                        'U' => try self.decodeHexCodePoint(.U, &text),

                        else => return error.UnexpectedCharacter,
                    }

                    self.inc(1);
                    continue :next self.next();
                },

                else => |c| {
                    try text.append(c);
                    self.inc(1);
                    continue :next self.next();
                },
            }
        }

        const Escape = enum(u8) {
            x = 2,
            u = 4,
            U = 8,

            pub fn characters(comptime escape: @This()) u8 {
                return @backingInt(escape);
            }

            pub fn cp(comptime escape: @This()) type {
                return switch (escape) {
                    .x => u8,
                    .u => u16,
                    .U => u32,
                };
            }
        };

        const DecodeHexCodePointError = OOM || error{UnexpectedCharacter};

        // TODO: should this append replacement characters instead of erroring?
        fn decodeHexCodePoint(
            self: *@This(),
            comptime escape: Escape,
            text: *std.array_list.Managed(enc.unit()),
        ) DecodeHexCodePointError!void {
            var value: escape.cp() = 0;
            for (0..@backingInt(escape)) |_| {
                self.inc(1);
                const digit = self.next();
                const num: u8 = switch (digit) {
                    '0'...'9' => @intCast(digit - '0'),
                    'a'...'f' => @intCast(digit - 'a' + 10),
                    'A'...'F' => @intCast(digit - 'A' + 10),
                    else => return error.UnexpectedCharacter,
                };

                value = value * 16 + num;
            }

            var scalar_value: u32 = @intCast(value);
            if (escape == .u and scalar_value >= 0xd800 and scalar_value <= 0xdbff) {
                if (self.peek(1) != '\\' or self.peek(2) != 'u') {
                    return error.UnexpectedCharacter;
                }

                self.inc(2);
                var low: u16 = 0;
                for (0..Escape.u.characters()) |_| {
                    self.inc(1);
                    low = low * 16 + switch (self.next()) {
                        '0'...'9' => |digit| @as(u16, @intCast(digit - '0')),
                        'a'...'f' => |digit| @as(u16, @intCast(digit - 'a' + 10)),
                        'A'...'F' => |digit| @as(u16, @intCast(digit - 'A' + 10)),
                        else => return error.UnexpectedCharacter,
                    };
                }
                if (low < 0xdc00 or low > 0xdfff) return error.UnexpectedCharacter;

                scalar_value = 0x10000 +
                    ((scalar_value - 0xd800) << 10) +
                    (@as(u32, low) - 0xdc00);
            } else if (scalar_value >= 0xd800 and scalar_value <= 0xdfff) {
                return error.UnexpectedCharacter;
            }

            const cp = std.math.cast(u21, scalar_value) orelse return error.UnexpectedCharacter;

            switch (enc) {
                .utf8 => {
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cp, &buf) catch {
                        return error.UnexpectedCharacter;
                    };
                    try text.appendSlice(buf[0..len]);
                },
                .utf16 => {
                    const len = std.unicode.utf16CodepointSequenceLength(cp) catch {
                        return error.UnexpectedCharacter;
                    };

                    switch (len) {
                        1 => try text.append(@intCast(cp)),
                        2 => {
                            const val = cp - 0x10000;
                            const high: u16 = 0xd800 + @as(u16, @intCast(val >> 10));
                            const low: u16 = 0xdc00 + @as(u16, @intCast(val & 0x3ff));
                            try text.appendSlice(&.{ high, low });
                        },
                        else => return error.UnexpectedCharacter,
                    }
                },
                .latin1 => {
                    if (cp > 0xff) {
                        return error.UnexpectedCharacter;
                    }
                    try text.append(@intCast(cp));
                },
            }
        }

        const ScanTagPropertyError = error{ UnresolvedTagHandle, UnexpectedCharacter };

        // c-ns-tag-property
        fn scanTagProperty(self: *@This()) ScanTagPropertyError!Token(enc) {
            const start = self.pos;

            // already at '!'
            self.inc(1);

            switch (self.next()) {
                0,
                ' ',
                '\t',
                '\n',
                '\r',
                => {
                    // c-non-specific-tag
                    // primary tag handle

                    return .tag(.{
                        .start = start,
                        .indent = self.line_indent,
                        .line = self.line,
                        .tag = .non_specific,
                    });
                },

                '<' => {
                    // c-verbatim-tag

                    self.inc(1);

                    const prefix = prefix: {
                        if (self.next() == '!') {
                            self.inc(1);
                            var range = self.stringRange();
                            self.skipNsUriChars();
                            break :prefix range.end();
                        }

                        if (self.isNsTagChar()) |len| {
                            var range = self.stringRange();
                            self.inc(len);
                            self.skipNsUriChars();
                            break :prefix range.end();
                        }

                        return error.UnexpectedCharacter;
                    };

                    try self.trySkipChar('>');

                    return .tag(.{
                        .start = start,
                        .indent = self.line_indent,
                        .line = self.line,
                        .tag = .{ .verbatim = prefix },
                    });
                },

                '!' => {
                    // c-ns-shorthand-tag
                    // secondary tag handle

                    self.inc(1);
                    var range = self.stringRange();
                    try self.trySkipNsTagChars();

                    // s-separate
                    switch (self.next()) {
                        0,
                        ' ',
                        '\t',
                        '\r',
                        '\n',
                        => {},

                        ',',
                        '[',
                        ']',
                        '{',
                        '}',
                        => {
                            switch (self.context.get()) {
                                .block_out,
                                .block_in,
                                => {
                                    return error.UnexpectedCharacter;
                                },
                                .flow_in,
                                .flow_key,
                                => {},
                            }
                        },
                        else => {
                            return error.UnexpectedCharacter;
                        },
                    }

                    const shorthand = range.end();

                    const tag: NodeTag = tag: {
                        const s = shorthand.slice(self.input);
                        if (std.mem.eql(enc.unit(), s, "bool")) {
                            break :tag .bool;
                        }
                        if (std.mem.eql(enc.unit(), s, "int")) {
                            break :tag .int;
                        }
                        if (std.mem.eql(enc.unit(), s, "float")) {
                            break :tag .float;
                        }
                        if (std.mem.eql(enc.unit(), s, "null")) {
                            break :tag .null;
                        }
                        if (std.mem.eql(enc.unit(), s, "str")) {
                            break :tag .str;
                        }

                        break :tag .{ .unknown = shorthand };
                    };

                    return .tag(.{
                        .start = start,
                        .indent = self.line_indent,
                        .line = self.line,
                        .tag = tag,
                    });
                },

                else => {
                    // c-ns-shorthand-tag
                    // named tag handle

                    var range = self.stringRange();
                    try self.trySkipNsWordChars();
                    var handle_or_shorthand = range.end();

                    if (self.next() == '!') {
                        self.inc(1);
                        if (!self.tag_handles.contains(handle_or_shorthand.slice(self.input))) {
                            self.pos = range.off;
                            return error.UnresolvedTagHandle;
                        }

                        range = self.stringRange();
                        try self.trySkipNsTagChars();
                        const shorthand = range.end();

                        return .tag(.{
                            .start = start,
                            .indent = self.line_indent,
                            .line = self.line,
                            .tag = .{ .unknown = shorthand },
                        });
                    }

                    // primary
                    self.skipNsTagChars();
                    handle_or_shorthand = range.end();

                    const tag: NodeTag = tag: {
                        const s = handle_or_shorthand.slice(self.input);
                        if (std.mem.eql(enc.unit(), s, "bool")) {
                            break :tag .bool;
                        }
                        if (std.mem.eql(enc.unit(), s, "int")) {
                            break :tag .int;
                        }
                        if (std.mem.eql(enc.unit(), s, "float")) {
                            break :tag .float;
                        }
                        if (std.mem.eql(enc.unit(), s, "null")) {
                            break :tag .null;
                        }
                        if (std.mem.eql(enc.unit(), s, "str")) {
                            break :tag .str;
                        }

                        break :tag .{ .unknown = handle_or_shorthand };
                    };

                    return .tag(.{
                        .start = start,
                        .indent = self.line_indent,
                        .line = self.line,
                        .tag = tag,
                    });
                },
            }
        }

        const ScanError = OOM || error{
            UnexpectedToken,
            UnexpectedCharacter,
            UnresolvedTagHandle,
            UnexpectedDocumentStart,
            UnexpectedDocumentEnd,
            InvalidIndentation,
        };

        const ScanOptions = struct {
            /// Used by compact sequences. We need to add
            /// the parent indentation
            /// ```
            /// - - - - one # indent = 4 + 2
            ///       - two
            /// ```
            additional_parent_indent: ?Indent = null,

            /// If a scalar is scanned, this tag might be used.
            tag: NodeTag = .none,

            /// The scanner only counts indentation after a newline
            /// (or in compact collections). First scan needs to
            /// count indentation.
            first_scan: bool = false,

            /// Spaces after a block indicator count as indentation for a
            /// compact collection.
            block_indented: bool = false,

            outside_context: bool = false,
        };

        fn scan(self: *@This(), opts: ScanOptions) ScanError!void {
            const ScanCtx = struct {
                parser: *Parser(enc),

                count_indentation: bool,
                in_indentation: bool,
                tab_after_indent: bool,
                additional_parent_indent: ?Indent,

                pub fn scanWhitespace(ctx: *@This(), comptime ws: enc.unit()) ScanError!enc.unit() {
                    const parser = ctx.parser;

                    switch (ws) {
                        '\r' => {
                            if (parser.peek(1) == '\n') {
                                parser.inc(1);
                            }

                            return '\n';
                        },
                        '\n' => {
                            ctx.count_indentation = true;
                            ctx.in_indentation = true;
                            ctx.tab_after_indent = false;
                            ctx.additional_parent_indent = null;

                            parser.newline();
                            parser.inc(1);
                            return parser.next();
                        },
                        ' ' => {
                            var total: usize = 1;
                            parser.inc(1);

                            while (parser.next() == ' ') {
                                parser.inc(1);
                                total += 1;
                            }

                            if (ctx.count_indentation) {
                                const parent_indent = if (ctx.additional_parent_indent) |additional| additional.cast() else 0;
                                parser.line_indent = .from(total + parent_indent);
                            }

                            ctx.count_indentation = false;

                            return parser.next();
                        },
                        '\t' => {
                            if (ctx.in_indentation) {
                                ctx.tab_after_indent = true;
                                parser.tab_after_indent = true;
                            }
                            ctx.count_indentation = false;
                            ctx.in_indentation = false;
                            parser.inc(1);
                            return parser.next();
                        },
                        else => @compileError("unexpected character"),
                    }
                }
            };

            const in_indentation = opts.first_scan or opts.block_indented or opts.additional_parent_indent != null;
            var ctx: ScanCtx = .{
                .parser = self,

                .count_indentation = opts.first_scan or opts.additional_parent_indent != null,
                .in_indentation = in_indentation,
                .tab_after_indent = self.tab_after_indent,
                .additional_parent_indent = opts.additional_parent_indent,
            };

            const previous_token_line = self.token.line;

            self.token = next: switch (self.next()) {
                0 => {
                    const start = self.pos;
                    break :next .eof(.{
                        .start = start,
                        .indent = self.line_indent,
                        .line = self.line,
                    });
                },
                '-' => {
                    const start = self.pos;

                    if (self.isDocumentIndicator("---")) {
                        self.inc(3);
                        break :next .documentStart(.{
                            .start = start,
                            .indent = self.line_indent,
                            .line = self.line,
                        });
                    }

                    switch (self.peek(1)) {

                        // eof
                        // b-char
                        // s-white
                        0,
                        '\n',
                        '\r',
                        ' ',
                        '\t',
                        => {
                            self.inc(1);

                            switch (self.context.get()) {
                                .block_out,
                                .block_in,
                                => {},
                                .flow_in,
                                .flow_key,
                                => {
                                    self.token.start = start;
                                    return unexpectedToken();
                                },
                            }

                            break :next .sequenceEntry(.{
                                .start = start,
                                .indent = self.line_indent,
                                .line = self.line,
                            });
                        },

                        // c-flow-indicator
                        ',',
                        ']',
                        '[',
                        '}',
                        '{',
                        => {
                            switch (self.context.get()) {
                                .flow_in,
                                .flow_key,
                                => {
                                    self.inc(1);

                                    self.token = .sequenceEntry(.{
                                        .start = start,
                                        .indent = self.line_indent,
                                        .line = self.line,
                                    });

                                    return unexpectedToken();
                                },
                                .block_in,
                                .block_out,
                                => {
                                    //  scanPlainScalar
                                },
                            }
                        },

                        else => {
                            //  scanPlainScalar
                        },
                    }

                    break :next try self.scanPlainScalar(opts);
                },
                '.' => {
                    const start = self.pos;

                    if (self.isDocumentIndicator("...")) {
                        self.inc(3);
                        break :next .documentEnd(.{
                            .start = start,
                            .indent = self.line_indent,
                            .line = self.line,
                        });
                    }

                    break :next try self.scanPlainScalar(opts);
                },
                '?' => {
                    const start = self.pos;

                    switch (self.peek(1)) {
                        // eof
                        // s-white
                        // b-char
                        0,
                        ' ',
                        '\t',
                        '\n',
                        '\r',
                        => {
                            self.inc(1);
                            break :next .mappingKey(.{
                                .start = start,
                                .indent = self.line_indent,
                                .line = self.line,
                            });
                        },

                        // c-flow-indicator
                        ',',
                        ']',
                        '[',
                        '}',
                        '{',
                        => {
                            switch (self.context.get()) {
                                .block_in,
                                .block_out,
                                => {
                                    // scanPlainScalar
                                },
                                .flow_in,
                                .flow_key,
                                => {
                                    self.inc(1);
                                    break :next .mappingKey(.{
                                        .start = start,
                                        .indent = self.line_indent,
                                        .line = self.line,
                                    });
                                },
                            }
                        },

                        else => {
                            // scanPlainScalar
                        },
                    }

                    break :next try self.scanPlainScalar(opts);
                },
                ':' => {
                    const start = self.pos;

                    switch (self.peek(1)) {
                        0,
                        ' ',
                        '\t',
                        '\n',
                        '\r',
                        => {
                            self.inc(1);
                            break :next .mappingValue(.{
                                .start = start,
                                .indent = self.line_indent,
                                .line = self.line,
                            });
                        },

                        // c-flow-indicator
                        ',',
                        ']',
                        '[',
                        '}',
                        '{',
                        => {
                            // scanPlainScalar
                            switch (self.context.get()) {
                                .block_in,
                                .block_out,
                                => {
                                    // scanPlainScalar
                                },
                                .flow_in,
                                .flow_key,
                                => {
                                    self.inc(1);
                                    break :next .mappingValue(.{
                                        .start = start,
                                        .indent = self.line_indent,
                                        .line = self.line,
                                    });
                                },
                            }
                        },

                        else => {
                            switch (self.context.get()) {
                                .block_in,
                                .block_out,
                                .flow_in,
                                => {
                                    // scanPlainScalar
                                },
                                .flow_key,
                                => {
                                    self.inc(1);
                                    break :next .mappingValue(.{
                                        .start = start,
                                        .indent = self.line_indent,
                                        .line = self.line,
                                    });
                                },
                            }
                        },
                    }

                    break :next try self.scanPlainScalar(opts);
                },
                ',' => {
                    const start = self.pos;

                    switch (self.context.get()) {
                        .flow_in,
                        .flow_key,
                        => {
                            self.inc(1);
                            break :next .collectEntry(.{
                                .start = start,
                                .indent = self.line_indent,
                                .line = self.line,
                            });
                        },
                        .block_in,
                        .block_out,
                        => {},
                    }

                    break :next try self.scanPlainScalar(opts);
                },
                '[' => {
                    const start = self.pos;

                    self.inc(1);
                    break :next .sequenceStart(.{
                        .start = start,
                        .indent = self.line_indent,
                        .line = self.line,
                    });
                },
                ']' => {
                    const start = self.pos;

                    self.inc(1);
                    break :next .sequenceEnd(.{
                        .start = start,
                        .indent = self.line_indent,
                        .line = self.line,
                    });
                },
                '{' => {
                    const start = self.pos;

                    self.inc(1);
                    break :next .mappingStart(.{
                        .start = start,
                        .indent = self.line_indent,
                        .line = self.line,
                    });
                },
                '}' => {
                    const start = self.pos;

                    self.inc(1);
                    break :next .mappingEnd(.{
                        .start = start,
                        .indent = self.line_indent,
                        .line = self.line,
                    });
                },
                '#' => {
                    const start = self.pos;

                    if (!self.isAtLineStart()) {
                        switch (self.input[start.cast() - 1]) {
                            ' ', '\t' => {},
                            else => return error.UnexpectedCharacter,
                        }
                    }

                    self.inc(1);
                    while (!self.isBCharOrEof()) {
                        self.inc(1);
                    }
                    continue :next self.next();
                },
                '&' => {
                    const start = self.pos;

                    self.inc(1);

                    var range = self.stringRange();
                    try self.trySkipNsAnchorChars();

                    const anchor: Token(enc) = .anchor(.{
                        .start = start,
                        .indent = self.line_indent,
                        .line = self.line,
                        .name = range.end(),
                    });

                    switch (self.next()) {
                        0,
                        ' ',
                        '\t',
                        '\n',
                        '\r',
                        => {
                            break :next anchor;
                        },

                        ',',
                        ']',
                        '[',
                        '}',
                        '{',
                        => {
                            switch (self.context.get()) {
                                .block_in,
                                .block_out,
                                => {},
                                .flow_key,
                                .flow_in,
                                => {
                                    break :next anchor;
                                },
                            }
                        },

                        else => {},
                    }

                    return error.UnexpectedCharacter;
                },
                '*' => {
                    const start = self.pos;

                    self.inc(1);

                    var range = self.stringRange();
                    try self.trySkipNsAnchorChars();

                    const alias: Token(enc) = .alias(.{
                        .start = start,
                        .indent = self.line_indent,
                        .line = self.line,
                        .name = range.end(),
                    });

                    switch (self.next()) {
                        0,
                        ' ',
                        '\t',
                        '\n',
                        '\r',
                        => {
                            break :next alias;
                        },

                        ',',
                        ']',
                        '[',
                        '}',
                        '{',
                        => {
                            switch (self.context.get()) {
                                .block_in,
                                .block_out,
                                => {},
                                .flow_key,
                                .flow_in,
                                => {
                                    break :next alias;
                                },
                            }
                        },

                        else => {},
                    }

                    return error.UnexpectedCharacter;
                },
                '!' => {
                    break :next try self.scanTagProperty();
                },
                '|' => {
                    const start = self.pos;

                    switch (self.context.get()) {
                        .block_out,
                        .block_in,
                        => {
                            self.inc(1);
                            break :next try self.scanLiteralScalar();
                        },
                        .flow_in,
                        .flow_key,
                        => {},
                    }
                    self.token.start = start;
                    return unexpectedToken();
                },
                '>' => {
                    const start = self.pos;

                    switch (self.context.get()) {
                        .block_out,
                        .block_in,
                        => {
                            self.inc(1);
                            break :next try self.scanFoldedScalar();
                        },
                        .flow_in,
                        .flow_key,
                        => {},
                    }
                    self.token.start = start;
                    return unexpectedToken();
                },
                '\'' => {
                    self.inc(1);
                    break :next try self.scanSingleQuotedScalar();
                },
                '"' => {
                    self.inc(1);
                    break :next try self.scanDoubleQuotedScalar();
                },
                '%' => {
                    const start = self.pos;

                    self.inc(1);
                    break :next .directive(.{
                        .start = start,
                        .indent = self.line_indent,
                        .line = self.line,
                    });
                },
                '@', '`' => {
                    const start = self.pos;

                    self.inc(1);
                    self.token = .reserved(.{
                        .start = start,
                        .indent = self.line_indent,
                        .line = self.line,
                    });
                    return unexpectedToken();
                },

                inline '\r',
                '\n',
                ' ',
                '\t',
                => |ws| continue :next try ctx.scanWhitespace(ws),

                else => {
                    break :next try self.scanPlainScalar(opts);
                },
            };

            switch (self.context.get()) {
                .block_out,
                .block_in,
                => {},
                .flow_in,
                .flow_key,
                => {
                    if (self.block_indents.get()) |block_indent| {
                        if (!opts.outside_context and self.token.line != previous_token_line and self.token.indent.isLessThanOrEqual(block_indent)) {
                            return unexpectedToken();
                        }
                    }
                },
            }

            self.token.tab_after_indent = ctx.tab_after_indent or self.tab_after_indent;
        }

        fn isChar(self: *@This(), char: enc.unit()) bool {
            const pos = self.pos;
            if (pos.isLessThan(self.input.len)) {
                return self.input[pos.cast()] == char;
            }
            return false;
        }

        fn trySkipChar(self: *@This(), char: enc.unit()) error{UnexpectedCharacter}!void {
            if (!self.isChar(char)) {
                return error.UnexpectedCharacter;
            }
            self.inc(1);
        }

        fn isNsWordChar(self: *@This()) bool {
            const pos = self.pos;
            if (pos.isLessThan(self.input.len)) {
                return chars.isNsWordChar(self.input[pos.cast()]);
            }
            return false;
        }

        /// ns-char
        fn isNsChar(self: *@This()) bool {
            const pos = self.pos;
            if (pos.isLessThan(self.input.len)) {
                return chars.isNsChar(self.input[pos.cast()]);
            }
            return false;
        }

        fn skipNsChars(self: *@This()) void {
            while (self.isNsChar()) {
                self.inc(1);
            }
        }

        fn trySkipNsChars(self: *@This()) error{UnexpectedCharacter}!void {
            if (!self.isNsChar()) {
                return error.UnexpectedCharacter;
            }
            self.skipNsChars();
        }

        fn isNsTagChar(self: *@This()) ?u8 {
            const r = self.remain();
            return chars.isNsTagChar(r);
        }

        fn skipNsTagChars(self: *@This()) void {
            while (self.isNsTagChar()) |len| {
                self.inc(len);
            }
        }

        fn trySkipNsTagChars(self: *@This()) error{UnexpectedCharacter}!void {
            const first_len = self.isNsTagChar() orelse {
                return error.UnexpectedCharacter;
            };
            self.inc(first_len);
            while (self.isNsTagChar()) |len| {
                self.inc(len);
            }
        }

        fn isNsAnchorChar(self: *@This()) bool {
            const pos = self.pos;
            if (pos.isLessThan(self.input.len)) {
                return chars.isNsAnchorChar(self.input[pos.cast()]);
            }
            return false;
        }

        fn trySkipNsAnchorChars(self: *@This()) error{UnexpectedCharacter}!void {
            if (!self.isNsAnchorChar()) {
                return error.UnexpectedCharacter;
            }
            self.inc(1);
            while (self.isNsAnchorChar()) {
                self.inc(1);
            }
        }

        /// s-l-comments
        ///
        /// positions `pos` on the next newline, or eof. Errors
        fn trySkipToNewLine(self: *@This()) error{UnexpectedCharacter}!void {
            var whitespace = false;

            if (self.isSWhite()) {
                whitespace = true;
                self.skipSWhite();
            }

            if (self.isChar('#')) {
                if (!whitespace) {
                    return error.UnexpectedCharacter;
                }
                self.inc(1);
                while (!self.isChar('\n') and !self.isChar('\r')) {
                    self.inc(1);
                }
            }

            if (self.pos.isLessThan(self.input.len) and !self.isChar('\n') and !self.isChar('\r')) {
                return error.UnexpectedCharacter;
            }
        }

        fn isAtLineStart(self: *const @This()) bool {
            const pos = self.pos.cast();
            if (pos == enc.bomLen(self.input)) return true;
            if (pos == 0) return false;
            return switch (self.input[pos - 1]) {
                '\n', '\r' => true,
                else => false,
            };
        }

        fn rejectTabAsIndentation(self: *const @This(), tab_after_indent: bool) error{InvalidIndentation}!void {
            if (!tab_after_indent) return;

            switch (self.context.get()) {
                .block_out, .block_in => return error.InvalidIndentation,
                .flow_in, .flow_key => {},
            }
        }

        fn isDocumentIndicator(self: *const @This(), comptime indicator: []const u8) bool {
            return self.isAtLineStart() and
                self.remainStartsWith(enc.literal(indicator)) and
                self.isSWhiteOrBCharOrEofAt(indicator.len);
        }

        fn isSWhiteOrBCharOrEofAt(self: *const @This(), n: usize) bool {
            const pos = self.pos.add(n);
            if (pos.isLessThan(self.input.len)) {
                const c = self.input[pos.cast()];
                return c == ' ' or c == '\t' or c == '\n' or c == '\r';
            }
            return true;
        }

        fn isEof(self: *const @This()) bool {
            return !self.pos.isLessThan(self.input.len);
        }

        fn isBChar(self: *@This()) bool {
            const pos = self.pos;
            if (pos.isLessThan(self.input.len)) {
                return chars.isBChar(self.input[pos.cast()]);
            }
            return false;
        }

        fn isBCharOrEof(self: *@This()) bool {
            const pos = self.pos;
            if (pos.isLessThan(self.input.len)) {
                return chars.isBChar(self.input[pos.cast()]);
            }
            return true;
        }

        fn isSWhite(self: *@This()) bool {
            const pos = self.pos;
            if (pos.isLessThan(self.input.len)) {
                return chars.isSWhite(self.input[pos.cast()]);
            }
            return false;
        }

        fn isSWhiteAt(self: *@This(), n: usize) bool {
            const pos = self.pos.add(n);
            if (pos.isLessThan(self.input.len)) {
                return chars.isSWhite(self.input[pos.cast()]);
            }
            return false;
        }

        fn skipSWhite(self: *@This()) void {
            while (self.isSWhite()) {
                self.inc(1);
            }
        }

        fn trySkipSWhite(self: *@This()) error{UnexpectedCharacter}!void {
            if (!self.isSWhite()) {
                return error.UnexpectedCharacter;
            }
            while (self.isSWhite()) {
                self.inc(1);
            }
        }

        fn isNsHexDigit(self: *@This()) bool {
            const pos = self.pos;
            if (pos.isLessThan(self.input.len)) {
                return chars.isNsHexDigit(self.input[pos.cast()]);
            }
            return false;
        }

        fn isNsDecDigit(self: *@This()) bool {
            const pos = self.pos;
            if (pos.isLessThan(self.input.len)) {
                return chars.isNsDecDigit(self.input[pos.cast()]);
            }
            return false;
        }

        fn skipNsDecDigits(self: *@This()) void {
            while (self.isNsDecDigit()) {
                self.inc(1);
            }
        }

        fn trySkipNsDecDigits(self: *@This()) error{UnexpectedCharacter}!void {
            if (!self.isNsDecDigit()) {
                return error.UnexpectedCharacter;
            }
            self.skipNsDecDigits();
        }

        fn skipNsWordChars(self: *@This()) void {
            while (self.isNsWordChar()) {
                self.inc(1);
            }
        }

        fn trySkipNsWordChars(self: *@This()) error{UnexpectedCharacter}!void {
            if (!self.isNsWordChar()) {
                return error.UnexpectedCharacter;
            }
            self.skipNsWordChars();
        }

        fn isNsUriChar(self: *@This()) bool {
            return chars.isNsUriChar(self.remain());
        }

        fn skipNsUriChars(self: *@This()) void {
            while (self.isNsUriChar()) {
                self.inc(1);
            }
        }

        fn stringRange(self: *const @This()) String.Range.Start {
            return .{
                .off = self.pos,
                .parser = self,
            };
        }

        fn stringBuilder(self: *@This()) String.Builder {
            return .{
                .parser = self,
                .str = .{ .range = .{ .off = .zero, .end = .zero } },
            };
        }

        pub const String = union(enum) {
            range: Range,
            list: std.array_list.Managed(enc.unit()),

            pub fn init(data: anytype) String {
                return switch (@TypeOf(data)) {
                    Range => .{ .range = data },
                    std.array_list.Managed(enc.unit()) => .{ .list = data },
                    else => @compileError("unexpected type"),
                };
            }

            pub fn deinit(self: *@This()) void {
                switch (self.*) {
                    .range => {},
                    .list => |*list| list.deinit(),
                }
            }

            pub fn slice(self: *const @This(), input: []const enc.unit()) []const enc.unit() {
                return switch (self.*) {
                    .range => |range| range.slice(input),
                    .list => |list| list.items,
                };
            }

            pub fn len(self: *const @This()) usize {
                return switch (self.*) {
                    .range => |*range| range.len(),
                    .list => |*list| list.items.len,
                };
            }

            pub fn isEmpty(self: *const @This()) bool {
                return switch (self.*) {
                    .range => |*range| range.isEmpty(),
                    .list => |*list| list.items.len == 0,
                };
            }

            pub fn eql(l: *const @This(), r: []const u8, input: []const enc.unit()) bool {
                const l_slice = l.slice(input);
                return std.mem.eql(enc.unit(), l_slice, r);
            }

            pub const Builder = struct {
                parser: *Parser(enc),
                str: String,

                pub fn appendSource(self: *@This(), unit: enc.unit(), pos: Pos) OOM!void {
                    try self.drainWhitespace();

                    if (comptime Environment.ci_assert) {
                        const actual = self.parser.input[pos.cast()];
                        bun.assert(actual == unit);
                    }
                    switch (self.str) {
                        .range => |*range| {
                            if (range.isEmpty()) {
                                range.off = pos;
                                range.end = pos;
                            }

                            bun.assert(range.end == pos);

                            range.end = pos.add(1);
                        },
                        .list => |*list| {
                            try list.append(unit);
                        },
                    }
                }

                fn drainWhitespace(self: *@This()) OOM!void {
                    const parser = self.parser;
                    defer parser.whitespace_buf.clearRetainingCapacity();

                    for (parser.whitespace_buf.items) |ws| {
                        switch (ws) {
                            .source => |source| {
                                if (comptime Environment.ci_assert) {
                                    const actual = self.parser.input[source.pos.cast()];
                                    bun.assert(actual == source.unit);
                                }

                                switch (self.str) {
                                    .range => |*range| {
                                        if (range.isEmpty()) {
                                            range.off = source.pos;
                                            range.end = source.pos;
                                        }

                                        bun.assert(range.end == source.pos);

                                        range.end = source.pos.add(1);
                                    },
                                    .list => |*list| {
                                        try list.append(source.unit);
                                    },
                                }
                            },
                            .new => |unit| {
                                switch (self.str) {
                                    .range => |range| {
                                        var list: std.array_list.Managed(enc.unit()) = try .initCapacity(parser.allocator, range.len() + 1);
                                        list.appendSliceAssumeCapacity(range.slice(parser.input));
                                        list.appendAssumeCapacity(unit);
                                        self.str = .{ .list = list };
                                    },
                                    .list => |*list| {
                                        try list.append(unit);
                                    },
                                }
                            },
                        }
                    }
                }

                pub fn appendSourceWhitespace(self: *@This(), unit: enc.unit(), pos: Pos) OOM!void {
                    try self.parser.whitespace_buf.append(.{ .source = .{ .unit = unit, .pos = pos } });
                }

                pub fn appendWhitespace(self: *@This(), unit: enc.unit()) OOM!void {
                    try self.parser.whitespace_buf.append(.{ .new = unit });
                }

                pub fn appendWhitespaceNTimes(self: *@This(), unit: enc.unit(), n: usize) OOM!void {
                    try self.parser.whitespace_buf.appendNTimes(.{ .new = unit }, n);
                }

                pub fn appendSourceSlice(self: *@This(), off: Pos, end: Pos) OOM!void {
                    try self.drainWhitespace();
                    switch (self.str) {
                        .range => |*range| {
                            if (range.isEmpty()) {
                                range.off = off;
                                range.end = off;
                            }

                            bun.assert(range.end == off);

                            range.end = end;
                        },
                        .list => |*list| {
                            try list.appendSlice(self.parser.slice(off, end));
                        },
                    }
                }

                pub fn appendExpectedSourceSlice(self: *@This(), off: Pos, end: Pos, expected: []const enc.unit()) OOM!void {
                    try self.drainWhitespace();

                    if (comptime Environment.ci_assert) {
                        const actual = self.parser.slice(off, end);
                        bun.assert(std.mem.eql(enc.unit(), actual, expected));
                    }

                    switch (self.str) {
                        .range => |*range| {
                            if (range.isEmpty()) {
                                range.off = off;
                                range.end = off;
                            }

                            bun.assert(range.end == off);

                            range.end = end;
                        },
                        .list => |*list| {
                            try list.appendSlice(self.parser.slice(off, end));
                        },
                    }
                }

                pub fn append(self: *@This(), unit: enc.unit()) OOM!void {
                    try self.drainWhitespace();

                    const parser = self.parser;

                    switch (self.str) {
                        .range => |range| {
                            var list: std.array_list.Managed(enc.unit()) = try .initCapacity(parser.allocator, range.len() + 1);
                            list.appendSliceAssumeCapacity(range.slice(parser.input));
                            list.appendAssumeCapacity(unit);
                            self.str = .{ .list = list };
                        },
                        .list => |*list| {
                            try list.append(unit);
                        },
                    }
                }

                pub fn appendSlice(self: *@This(), str: []const enc.unit()) OOM!void {
                    if (str.len == 0) {
                        return;
                    }

                    try self.drainWhitespace();

                    const parser = self.parser;

                    switch (self.str) {
                        .range => |range| {
                            var list: std.array_list.Managed(enc.unit()) = try .initCapacity(parser.allocator, range.len() + str.len);
                            list.appendSliceAssumeCapacity(self.str.range.slice(parser.input));
                            list.appendSliceAssumeCapacity(str);
                            self.str = .{ .list = list };
                        },
                        .list => |*list| {
                            try list.appendSlice(str);
                        },
                    }
                }

                pub fn appendNTimes(self: *@This(), unit: enc.unit(), n: usize) OOM!void {
                    if (n == 0) {
                        return;
                    }

                    try self.drainWhitespace();

                    const parser = self.parser;

                    switch (self.str) {
                        .range => |range| {
                            var list: std.array_list.Managed(enc.unit()) = try .initCapacity(parser.allocator, range.len() + n);
                            list.appendSliceAssumeCapacity(self.str.range.slice(parser.input));
                            list.appendNTimesAssumeCapacity(unit, n);
                            self.str = .{ .list = list };
                        },
                        .list => |*list| {
                            try list.appendNTimes(unit, n);
                        },
                    }
                }

                pub fn len(this: *const @This()) usize {
                    return this.str.len();
                }

                pub fn done(self: *@This()) String {
                    self.parser.whitespace_buf.clearRetainingCapacity();
                    return self.str;
                }
            };

            pub const Range = struct {
                off: Pos,
                end: Pos,

                pub const Start = struct {
                    off: Pos,
                    parser: *const Parser(enc),

                    pub fn end(this: *const @This()) Range {
                        return .{
                            .off = this.off,
                            .end = this.parser.pos,
                        };
                    }
                };

                pub fn isEmpty(this: *const @This()) bool {
                    return this.off == this.end;
                }

                pub fn len(this: *const @This()) usize {
                    return this.end.cast() - this.off.cast();
                }

                pub fn slice(this: *const Range, input: []const enc.unit()) []const enc.unit() {
                    return input[this.off.cast()..this.end.cast()];
                }
            };
        };

        pub const NodeTag = union(enum) {
            /// ''
            none,

            /// '!'
            non_specific,

            /// '!!bool'
            bool,
            /// '!!int'
            int,
            /// '!!float'
            float,
            /// '!!null'
            null,
            /// '!!str'
            str,

            /// '!<...>'
            verbatim: String.Range,

            /// '!!unknown'
            unknown: String.Range,

            pub fn resolveNull(this: NodeTag, loc: logger.Loc) Expr {
                return switch (this) {
                    .none,
                    .bool,
                    .int,
                    .float,
                    .null,
                    .verbatim,
                    .unknown,
                    => .init(E.Null, .{}, loc),

                    // non-specific tags become seq, map, or str
                    .non_specific,
                    .str,
                    => .init(E.String, .{}, loc),
                };
            }
        };

        pub const NodeScalar = union(enum) {
            null,
            boolean: bool,
            number: f64,
            string: String,

            pub fn toExpr(this: *const NodeScalar, pos: Pos, input: []const enc.unit()) Expr {
                return switch (this.*) {
                    .null => .init(E.Null, .{}, pos.loc()),
                    .boolean => |value| .init(E.Boolean, .{ .value = value }, pos.loc()),
                    .number => |value| .init(E.Number, .{ .value = value }, pos.loc()),
                    .string => |value| .init(E.String, .{ .data = value.slice(input) }, pos.loc()),
                };
            }
        };

        const Directive = enum {
            yaml,
            other,
        };
    };
}

pub const Encoding = enum {
    latin1,
    utf8,
    utf16,

    pub fn unit(comptime encoding: Encoding) type {
        return switch (encoding) {
            .latin1 => u8,
            .utf8 => u8,
            .utf16 => u16,
        };
    }

    pub fn literal(comptime encoding: Encoding, comptime str: []const u8) []const encoding.unit() {
        return switch (encoding) {
            .latin1 => str,
            .utf8 => str,
            .utf16 => std.unicode.utf8ToUtf16LeStringLiteral(str),
        };
    }

    pub fn bomLen(comptime encoding: Encoding, input: []const encoding.unit()) usize {
        return switch (encoding) {
            .latin1 => 0,
            .utf8 => if (std.mem.startsWith(u8, input, "\xEF\xBB\xBF")) 3 else 0,
            .utf16 => if (input.len != 0 and input[0] == 0xFEFF) 1 else 0,
        };
    }

    pub fn chars(comptime encoding: Encoding) type {
        return struct {
            pub fn isNsDecDigit(c: encoding.unit()) bool {
                return switch (c) {
                    '0'...'9' => true,
                    else => false,
                };
            }
            pub fn isNsHexDigit(c: encoding.unit()) bool {
                return switch (c) {
                    '0'...'9',
                    'a'...'f',
                    'A'...'F',
                    => true,
                    else => false,
                };
            }
            pub fn isNsWordChar(c: encoding.unit()) bool {
                return switch (c) {
                    '0'...'9',
                    'A'...'Z',
                    'a'...'z',
                    '-',
                    => true,
                    else => false,
                };
            }
            pub fn isNsChar(c: encoding.unit()) bool {
                return switch (comptime encoding) {
                    .utf8 => switch (c) {
                        ' ', '\t' => false,
                        '\n', '\r' => false,

                        // TODO: exclude BOM

                        ' ' + 1...0x7e => true,

                        0x80...0xff => true,

                        // TODO: include 0x85, [0xa0 - 0xd7ff], [0xe000 - 0xfffd], [0x010000 - 0x10ffff]
                        else => false,
                    },
                    .utf16 => switch (c) {
                        ' ', '\t' => false,
                        '\n', '\r' => false,
                        // TODO: exclude BOM

                        ' ' + 1...0x7e => true,

                        0x85 => true,

                        0xa0...0xd7ff => true,
                        0xe000...0xfffd => true,

                        // TODO: include 0x85, [0xa0 - 0xd7ff], [0xe000 - 0xfffd], [0x010000 - 0x10ffff]
                        else => false,
                    },
                    .latin1 => switch (c) {
                        ' ', '\t' => false,
                        '\n', '\r' => false,

                        // TODO: !!!!
                        else => true,
                    },
                };
            }

            // null if false
            // length if true
            pub fn isNsTagChar(cs: []const encoding.unit()) ?u8 {
                if (cs.len == 0) {
                    return null;
                }

                return switch (cs[0]) {
                    '#',
                    ';',
                    '/',
                    '?',
                    ':',
                    '@',
                    '&',
                    '=',
                    '+',
                    '$',
                    '_',
                    '.',
                    '~',
                    '*',
                    '\'',
                    '(',
                    ')',
                    => 1,

                    '!',
                    ',',
                    '[',
                    ']',
                    '{',
                    '}',
                    => null,

                    else => |c| {
                        if (c == '%') {
                            if (cs.len > 2 and isNsHexDigit(cs[1]) and isNsHexDigit(cs[2])) {
                                return 3;
                            }
                        }

                        return if (isNsWordChar(c)) 1 else null;
                    },
                };
            }
            pub fn isBChar(c: encoding.unit()) bool {
                return c == '\n' or c == '\r';
            }
            pub fn isSWhite(c: encoding.unit()) bool {
                return c == ' ' or c == '\t';
            }
            pub fn isCFlowIndicator(c: encoding.unit()) bool {
                return switch (c) {
                    ',',
                    '[',
                    ']',
                    '{',
                    '}',
                    => true,
                    else => false,
                };
            }
            pub fn isNsUriChar(cs: []const encoding.unit()) bool {
                if (cs.len == 0) {
                    return false;
                }
                return switch (cs[0]) {
                    '#',
                    ';',
                    '/',
                    '?',
                    ':',
                    '@',
                    '&',
                    '=',
                    '+',
                    '$',
                    ',',
                    '_',
                    '.',
                    '!',
                    '~',
                    '*',
                    '\'',
                    '(',
                    ')',
                    '[',
                    ']',
                    => true,

                    else => |c| {
                        if (c == '%' and cs.len > 2 and isNsHexDigit(cs[1]) and isNsHexDigit(cs[2])) {
                            return true;
                        }

                        return isNsWordChar(c);
                    },
                };
            }
            pub fn isNsAnchorChar(c: encoding.unit()) bool {
                // TODO: inline isCFlowIndicator
                return isNsChar(c) and !isCFlowIndicator(c);
            }
        };
    }
};

pub fn Token(comptime encoding: Encoding) type {
    const NodeTag = Parser(encoding).NodeTag;
    const NodeScalar = Parser(encoding).NodeScalar;
    const String = Parser(encoding).String;

    return struct {
        start: Pos,
        indent: Indent,
        tab_after_indent: bool = false,
        line: Line,
        data: Data,

        const TokenInit = struct {
            start: Pos,
            indent: Indent,
            line: Line,
        };

        pub fn eof(init: TokenInit) @This() {
            return .{
                .start = init.start,
                .indent = init.indent,
                .line = init.line,
                .data = .eof,
            };
        }

        pub fn sequenceEntry(init: TokenInit) @This() {
            return .{
                .start = init.start,
                .indent = init.indent,
                .line = init.line,
                .data = .sequence_entry,
            };
        }

        pub fn mappingKey(init: TokenInit) @This() {
            return .{
                .start = init.start,
                .indent = init.indent,
                .line = init.line,
                .data = .mapping_key,
            };
        }

        pub fn mappingValue(init: TokenInit) @This() {
            return .{
                .start = init.start,
                .indent = init.indent,
                .line = init.line,
                .data = .mapping_value,
            };
        }

        pub fn collectEntry(init: TokenInit) @This() {
            return .{
                .start = init.start,
                .indent = init.indent,
                .line = init.line,
                .data = .collect_entry,
            };
        }

        pub fn sequenceStart(init: TokenInit) @This() {
            return .{
                .start = init.start,
                .indent = init.indent,
                .line = init.line,
                .data = .sequence_start,
            };
        }

        pub fn sequenceEnd(init: TokenInit) @This() {
            return .{
                .start = init.start,
                .indent = init.indent,
                .line = init.line,
                .data = .sequence_end,
            };
        }

        pub fn mappingStart(init: TokenInit) @This() {
            return .{
                .start = init.start,
                .indent = init.indent,
                .line = init.line,
                .data = .mapping_start,
            };
        }

        pub fn mappingEnd(init: TokenInit) @This() {
            return .{
                .start = init.start,
                .indent = init.indent,
                .line = init.line,
                .data = .mapping_end,
            };
        }

        const AnchorInit = struct {
            start: Pos,
            indent: Indent,
            line: Line,
            name: String.Range,
        };

        pub fn anchor(init: AnchorInit) @This() {
            return .{
                .start = init.start,
                .indent = init.indent,
                .line = init.line,
                .data = .{ .anchor = init.name },
            };
        }

        const AliasInit = struct {
            start: Pos,
            indent: Indent,
            line: Line,
            name: String.Range,
        };

        pub fn alias(init: AliasInit) @This() {
            return .{
                .start = init.start,
                .indent = init.indent,
                .line = init.line,
                .data = .{ .alias = init.name },
            };
        }

        const TagInit = struct {
            start: Pos,
            indent: Indent,
            line: Line,
            tag: NodeTag,
        };

        pub fn tag(init: TagInit) @This() {
            return .{
                .start = init.start,
                .indent = init.indent,
                .line = init.line,
                .data = .{ .tag = init.tag },
            };
        }

        pub fn directive(init: TokenInit) @This() {
            return .{
                .start = init.start,
                .indent = init.indent,
                .line = init.line,
                .data = .directive,
            };
        }

        pub fn reserved(init: TokenInit) @This() {
            return .{
                .start = init.start,
                .indent = init.indent,
                .line = init.line,
                .data = .reserved,
            };
        }

        pub fn documentStart(init: TokenInit) @This() {
            return .{
                .start = init.start,
                .indent = init.indent,
                .line = init.line,
                .data = .document_start,
            };
        }

        pub fn documentEnd(init: TokenInit) @This() {
            return .{
                .start = init.start,
                .indent = init.indent,
                .line = init.line,
                .data = .document_end,
            };
        }

        const ScalarInit = struct {
            start: Pos,
            indent: Indent,
            line: Line,

            resolved: Scalar,
        };

        pub fn scalar(init: ScalarInit) @This() {
            return .{
                .start = init.start,
                .indent = init.indent,
                .line = init.line,
                .data = .{ .scalar = init.resolved },
            };
        }

        pub const Data = union(enum) {
            eof,
            /// `-`
            sequence_entry,
            /// `?`
            mapping_key,
            /// `:`
            mapping_value,
            /// `,`
            collect_entry,
            /// `[`
            sequence_start,
            /// `]`
            sequence_end,
            /// `{`
            mapping_start,
            /// `}`
            mapping_end,
            /// `&`
            anchor: String.Range,
            /// `*`
            alias: String.Range,
            /// `!`
            tag: NodeTag,
            /// `%`
            directive,
            /// `@` or `\``
            reserved,
            /// `---`
            document_start,
            /// `...`
            document_end,

            // might be single or double quoted, or unquoted.
            // might be a literal or folded literal ('|' or '>')
            scalar: Scalar,
        };

        pub const Scalar = struct {
            data: NodeScalar,
            multiline: bool,
        };
    };
}

const std = @import("std");

const bun = @import("bun");
const Environment = bun.Environment;
const OOM = bun.OOM;
const logger = bun.logger;

const ast = bun.ast;
const E = ast.E;
const Expr = ast.Expr;
const G = ast.G;
