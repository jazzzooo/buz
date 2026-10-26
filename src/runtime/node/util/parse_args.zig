const log = bun.Output.scoped(.parseArgs, .hidden);

fn bindingText(value: bun.bindgen.DOMStringView) TextView {
    return switch (value.unsafePtr("the generated entry frame owns the converted string until parseArgs copies its code units")) {
        .latin1 => |bytes| .{ .latin1 = bytes },
        .utf16 => |code_units| .{ .utf16 = code_units },
    };
}

const TokenKind = enum {
    positional,
    option,
    option_terminator,
};

const Token = union(TokenKind) {
    positional: struct { index: u32, value: TextView },
    option: OptionToken,
    option_terminator: struct { index: u32 },
};

const OptionToken = struct {
    index: u32,
    name: TextView,
    parse_type: enum {
        lone_short_option,
        short_option_and_value,
        lone_long_option,
        long_option_and_value,
    },
    value: ?TextView,
    inline_value: bool,
    optgroup_idx: ?usize = null,
    option_idx: ?usize,
    negative: bool = false,
    raw: TextView,

    const RawNameFormatter = struct {
        token: OptionToken,

        pub fn format(this: RawNameFormatter, writer: *std.Io.Writer) !void {
            const token = this.token;
            if (token.optgroup_idx) |optgroup_idx| {
                try writer.writeByte('-');
                var short = token.raw.substringWithLen(optgroup_idx, optgroup_idx + 1);
                try short.format(writer);
                return;
            }
            switch (token.parse_type) {
                .lone_short_option, .lone_long_option => {
                    var raw = token.raw;
                    try raw.format(writer);
                },
                .short_option_and_value => {
                    var short = token.raw.substringWithLen(0, 2);
                    try short.format(writer);
                },
                .long_option_and_value => {
                    const equal_index = token.raw.indexOfAsciiChar('=').?;
                    var name = token.raw.substringWithLen(0, equal_index);
                    try name.format(writer);
                },
            }
        }
    };

    fn rawName(this: OptionToken) bun.OOM!bun.bindgen.DOMString {
        if (this.optgroup_idx) |optgroup_idx| {
            var buffer: [8]u8 = undefined;
            const value = std.fmt.bufPrint(&buffer, "-{f}", .{
                this.raw.substringWithLen(optgroup_idx, optgroup_idx + 1),
            }) catch unreachable;
            return bun.bindgen.DOMString.fromUTF8(value);
        }
        return switch (this.parse_type) {
            .lone_short_option, .lone_long_option => bun.bindgen.DOMString.fromTextView(this.raw),
            .short_option_and_value => bun.bindgen.DOMString.fromTextView(this.raw.substringWithLen(0, 2)),
            .long_option_and_value => bun.bindgen.DOMString.fromTextView(
                this.raw.substringWithLen(0, this.raw.indexOfAsciiChar('=').?),
            ),
        };
    }
};

const StoredScalar = union(enum) {
    boolean: bool,
    string: TextView,
};

const StoredValue = union(enum) {
    single: StoredScalar,
    multiple: std.ArrayListUnmanaged(StoredScalar),
};

const StoredEntry = struct {
    name: TextView,
    value: StoredValue,
};

pub fn findOptionByLongName(long_name: TextView, options: []const OptionDefinition) ?usize {
    for (options, 0..) |option, index| {
        if (long_name.eqlUTF8View(option.long_name)) return index;
    }
    return null;
}

fn failMessage(
    context: ParseArgsContext,
    comptime tag: anytype,
    comptime format: []const u8,
    args: anytype,
) bun.bindgen.CallError(ParseArgsSchema) {
    const bytes = std.fmt.allocPrint(bun.default_allocator, format, args) catch return error.OutOfMemory;
    defer bun.default_allocator.free(bytes);
    const message = bun.bindgen.DOMString.fromUTF8(bytes) catch return error.OutOfMemory;
    return context.fail(tag, message);
}

fn checkOptionLikeValue(context: ParseArgsContext, token: OptionToken) bun.bindgen.CallError(ParseArgsSchema)!void {
    const value = token.value orelse return;
    if (token.inline_value or !isOptionLikeValue(value)) return;

    const raw_name = OptionToken.RawNameFormatter{ .token = token };
    if (token.raw.hasPrefixComptime("--")) {
        return failMessage(
            context,
            .invalid_option_value,
            "Option '{f}' argument is ambiguous.\nDid you forget to specify the option argument for '{f}'?\nTo specify an option argument starting with a dash use '{f}=-XYZ'.",
            .{ raw_name, raw_name, raw_name },
        );
    }
    return failMessage(
        context,
        .invalid_option_value,
        "Option '{f}' argument is ambiguous.\nDid you forget to specify the option argument for '{f}'?\nTo specify an option argument starting with a dash use '--{f}=-XYZ' or '{f}-XYZ'.",
        .{ raw_name, raw_name, token.name, raw_name },
    );
}

fn checkOptionUsage(
    context: ParseArgsContext,
    options: []const OptionDefinition,
    allow_positionals: bool,
    token: OptionToken,
) bun.bindgen.CallError(ParseArgsSchema)!void {
    if (token.option_idx) |option_idx| {
        const option = options[option_idx];
        switch (option.type) {
            .string => if (token.value == null) {
                if (token.negative) {
                    return failMessage(
                        context,
                        .unknown_option,
                        "Unknown option '{f}'",
                        .{OptionToken.RawNameFormatter{ .token = token }},
                    );
                }
                return failMessage(
                    context,
                    .invalid_option_value,
                    "Option '{s}{f}{s}--{f} <value>' argument missing",
                    .{
                        if (!option.short_name.isEmpty()) "-" else "",
                        option.short_name,
                        if (!option.short_name.isEmpty()) ", " else "",
                        token.name,
                    },
                );
            },
            .boolean => if (token.value != null) {
                return failMessage(
                    context,
                    .invalid_option_value,
                    "Option '{s}{f}{s}--{f}' does not take an argument",
                    .{
                        if (!option.short_name.isEmpty()) "-" else "",
                        option.short_name,
                        if (!option.short_name.isEmpty()) ", " else "",
                        token.name,
                    },
                );
            },
        }
        return;
    }

    const raw_name = OptionToken.RawNameFormatter{ .token = token };
    if (allow_positionals) {
        return failMessage(
            context,
            .unknown_option,
            "Unknown option '{f}'. To specify a positional argument starting with a '-', place it at the end of the command after '--', as in '-- \"{f}\"'",
            .{ raw_name, raw_name },
        );
    }
    return failMessage(context, .unknown_option, "Unknown option '{f}'", .{raw_name});
}

fn findStoredValue(values: []const StoredEntry, name: TextView) ?usize {
    for (values, 0..) |entry, index| {
        if (name.eqlUTF8View(entry.name)) return index;
    }
    return null;
}

fn storeOption(
    allocator: std.mem.Allocator,
    option_name: TextView,
    option_value: ?TextView,
    option_idx: ?usize,
    negative: bool,
    options: []const OptionDefinition,
    values: *std.ArrayListUnmanaged(StoredEntry),
) bun.OOM!void {
    if (option_name.eqlBytes("__proto__")) return;

    const scalar: StoredScalar = if (option_value) |value|
        .{ .string = value }
    else
        .{ .boolean = !negative };
    const is_multiple = if (option_idx) |index| options[index].multiple else false;

    if (findStoredValue(values.items, option_name)) |index| {
        if (is_multiple) {
            switch (values.items[index].value) {
                .multiple => |*items| try items.append(allocator, scalar),
                .single => unreachable,
            }
        } else {
            values.items[index].value = .{ .single = scalar };
        }
        return;
    }

    const value: StoredValue = if (is_multiple) value: {
        var items: std.ArrayListUnmanaged(StoredScalar) = .empty;
        try items.append(allocator, scalar);
        break :value .{ .multiple = items };
    } else .{ .single = scalar };
    try values.append(allocator, .{ .name = option_name, .value = value });
}

fn validateOptionDefault(
    context: ParseArgsContext,
    long_name: TextView,
    option_type: OptionValueType,
    multiple: bool,
    value: anytype,
) bun.bindgen.CallError(ParseArgsSchema)!void {
    const expected = @tagName(option_type);
    if (!multiple) {
        const matches = switch (value) {
            .string => option_type == .string,
            .boolean => option_type == .boolean,
            .array, .invalid => false,
        };
        if (!matches) {
            return failMessage(
                context,
                .invalid_arg_value,
                "\"options.{f}.default\" property must be of type {s}",
                .{ long_name, expected },
            );
        }
        return;
    }

    const values = switch (value) {
        .array => |values| values,
        .string, .boolean, .invalid => return failMessage(
            context,
            .invalid_arg_value,
            "\"options.{f}.default\" property must be an instance of Array",
            .{long_name},
        ),
    };
    for (0..values.len()) |index| {
        const matches = switch (values.at(index).?) {
            .string => option_type == .string,
            .boolean => option_type == .boolean,
            .invalid => false,
        };
        if (!matches) {
            return failMessage(
                context,
                .invalid_arg_value,
                "\"options.{f}.default[{d}]\" property must be of type {s}",
                .{ long_name, index, expected },
            );
        }
    }
}

fn parseOptionDefinitions(
    context: ParseArgsContext,
    options: anytype,
    allocator: std.mem.Allocator,
) bun.bindgen.CallError(ParseArgsSchema)![]OptionDefinition {
    var definitions: std.ArrayListUnmanaged(OptionDefinition) = .empty;
    for (0..options.len()) |index| {
        const entry = options.at(index).?;
        var option = OptionDefinition{
            .long_name = bindingText(entry.key),
            .type = switch (entry.value.option_type) {
                .boolean => .boolean,
                .string => .string,
            },
            .multiple = entry.value.multiple,
        };

        if (entry.value.short_name) |short_option| {
            const short_option_text = bindingText(short_option);
            if (short_option_text.len() != 1) {
                return failMessage(
                    context,
                    .invalid_arg_value,
                    "options.{f}.short must be a single character",
                    .{option.long_name},
                );
            }
            option.short_name = short_option_text;
        }

        if (entry.value.default_value) |default_value| {
            try validateOptionDefault(context, option.long_name, option.type, option.multiple, default_value);
            option.has_default = true;
        }

        log("[OptionDef] \"{f}\" (type={s}, short={f}, multiple={d}, default={s})", .{
            option.long_name,
            @tagName(option.type),
            if (!option.short_name.isEmpty()) option.short_name else bun.TextView{ .latin1 = "none" },
            @intFromBool(option.multiple),
            if (option.has_default) "yes" else "no",
        });

        try definitions.append(allocator, option);
    }
    return definitions.items;
}

fn tokenizeArgs(
    state: *ParseArgsState,
    args: []const TextView,
    options: []const OptionDefinition,
) bun.bindgen.CallError(ParseArgsSchema)!void {
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        const token_type = classifyToken(arg, options);
        log(" [Arg #{d}] {s} ({f})", .{ index, @tagName(token_type), arg });

        switch (token_type) {
            .option_terminator => {
                try state.handleToken(.{ .option_terminator = .{ .index = @intCast(index) } });
                index += 1;
                while (index < args.len) : (index += 1) {
                    try state.handleToken(.{ .positional = .{
                        .index = @intCast(index),
                        .value = args[index],
                    } });
                }
                break;
            },
            .lone_short_option => {
                const short_option = arg.substringWithLen(1, 2);
                const option_idx = findOptionByShortName(short_option, options);
                const option_type: OptionValueType = if (option_idx) |option_index| options[option_index].type else .boolean;
                var value: ?TextView = null;
                var inline_value = true;
                if (option_type == .string and index + 1 < args.len) {
                    value = args[index + 1];
                    inline_value = false;
                    log("   (lone_short_option consuming next token as value)", .{});
                }
                try state.handleToken(.{ .option = .{
                    .index = @intCast(index),
                    .value = value,
                    .inline_value = inline_value,
                    .name = if (option_idx) |option_index| options[option_index].long_name else short_option,
                    .parse_type = .lone_short_option,
                    .raw = arg,
                    .option_idx = option_idx,
                } });
                if (!inline_value) index += 1;
            },
            .short_option_group => {
                const original_arg_index: u32 = @intCast(index);
                const arg_len = arg.len();
                for (1..arg_len) |group_index| {
                    const short_option = arg.substringWithLen(group_index, group_index + 1);
                    const option_idx = findOptionByShortName(short_option, options);
                    const option_type: OptionValueType = if (option_idx) |option_index| options[option_index].type else .boolean;
                    if (option_type != .string or group_index == arg_len - 1) {
                        var value: ?TextView = null;
                        var inline_value = true;
                        if (option_type == .string and index + 1 < args.len) {
                            value = args[index + 1];
                            inline_value = false;
                            log("   (short_option_group short option consuming next token as value)", .{});
                        }
                        try state.handleToken(.{ .option = .{
                            .index = original_arg_index,
                            .optgroup_idx = group_index,
                            .value = value,
                            .inline_value = inline_value,
                            .name = if (option_idx) |option_index| options[option_index].long_name else short_option,
                            .parse_type = .lone_short_option,
                            .raw = arg,
                            .option_idx = option_idx,
                        } });
                        if (!inline_value) index += 1;
                    } else {
                        try state.handleToken(.{ .option = .{
                            .index = original_arg_index,
                            .optgroup_idx = group_index,
                            .value = arg.substring(group_index + 1),
                            .inline_value = true,
                            .name = if (option_idx) |option_index| options[option_index].long_name else short_option,
                            .parse_type = .short_option_and_value,
                            .raw = arg,
                            .option_idx = option_idx,
                        } });
                        break;
                    }
                }
            },
            .short_option_and_value => {
                const short_option = arg.substringWithLen(1, 2);
                const option_idx = findOptionByShortName(short_option, options);
                try state.handleToken(.{ .option = .{
                    .index = @intCast(index),
                    .value = arg.substring(2),
                    .inline_value = true,
                    .name = if (option_idx) |option_index| options[option_index].long_name else short_option,
                    .parse_type = .short_option_and_value,
                    .raw = arg.substringWithLen(0, 2),
                    .option_idx = option_idx,
                } });
            },
            .lone_long_option => {
                var long_option = arg.substring(2);
                long_option, const negative = if (state.allow_negative and long_option.hasPrefixComptime("no-"))
                    .{ long_option.substring(3), true }
                else
                    .{ long_option, false };

                const option_idx = findOptionByLongName(long_option, options);
                const option_type: OptionValueType = if (option_idx) |option_index| options[option_index].type else .boolean;
                const value: ?TextView = if (option_type == .string and index + 1 < args.len and !negative)
                    args[index + 1]
                else
                    null;
                try state.handleToken(.{ .option = .{
                    .index = @intCast(index),
                    .value = value,
                    .inline_value = value == null,
                    .name = long_option,
                    .parse_type = .lone_long_option,
                    .raw = arg,
                    .option_idx = option_idx,
                    .negative = negative,
                } });
                if (value != null) index += 1;
            },
            .long_option_and_value => {
                const equal_index = arg.indexOfAsciiChar('=').?;
                const long_option = arg.substringWithLen(2, equal_index);
                try state.handleToken(.{ .option = .{
                    .index = @intCast(index),
                    .value = arg.substring(equal_index + 1),
                    .inline_value = true,
                    .name = long_option,
                    .parse_type = .long_option_and_value,
                    .raw = arg,
                    .option_idx = findOptionByLongName(long_option, options),
                } });
            },
            .positional => try state.handleToken(.{ .positional = .{
                .index = @intCast(index),
                .value = arg,
            } }),
        }
    }
}

const ParseArgsState = struct {
    context: ParseArgsContext,
    allocator: std.mem.Allocator,
    option_defs: []const OptionDefinition,
    allow_positionals: bool,
    strict: bool,
    allow_negative: bool,
    return_tokens: bool,
    values: std.ArrayListUnmanaged(StoredEntry) = .empty,
    positionals: std.ArrayListUnmanaged(TextView) = .empty,
    tokens: std.ArrayListUnmanaged(Token) = .empty,

    fn handleToken(this: *ParseArgsState, token: Token) bun.bindgen.CallError(ParseArgsSchema)!void {
        switch (token) {
            .option => |option| {
                if (this.strict) {
                    try checkOptionUsage(this.context, this.option_defs, this.allow_positionals, option);
                    try checkOptionLikeValue(this.context, option);
                }
                try storeOption(
                    this.allocator,
                    option.name,
                    option.value,
                    option.option_idx,
                    option.negative,
                    this.option_defs,
                    &this.values,
                );
            },
            .positional => |positional| {
                if (!this.allow_positionals) {
                    return failMessage(
                        this.context,
                        .unexpected_positional,
                        "Unexpected argument '{f}'. This command does not take positional arguments",
                        .{positional.value},
                    );
                }
                try this.positionals.append(this.allocator, positional.value);
            },
            .option_terminator => {},
        }
        if (this.return_tokens) try this.tokens.append(this.allocator, token);
    }
};

fn outputScalar(value: StoredScalar) bun.OOM!ParseArgsOutputScalar {
    return switch (value) {
        .boolean => |boolean| .{ .boolean = boolean },
        .string => |text| .{ .string = try bun.bindgen.DOMString.fromTextView(text) },
    };
}

fn outputValue(value: StoredValue) bun.OOM!ParseArgsOutputValue {
    return switch (value) {
        .single => |scalar| switch (scalar) {
            .boolean => |boolean| .{ .boolean = boolean },
            .string => |text| .{ .string = try bun.bindgen.DOMString.fromTextView(text) },
        },
        .multiple => |stored| .{ .multiple = try ParseArgsOutputMultiple.fromMappedSlice(stored.items, outputScalar) },
    };
}

fn outputToken(token: Token) bun.OOM!ParseArgsOutputToken {
    return switch (token) {
        .option => |option| option_token: {
            var name = try bun.bindgen.DOMString.fromTextView(option.name);
            errdefer name.deinit();
            var raw_name = try option.rawName();
            errdefer raw_name.deinit();
            var value: ?bun.bindgen.DOMString = if (option.value) |text|
                try bun.bindgen.DOMString.fromTextView(text)
            else
                null;
            errdefer if (value) |*text| text.deinit();
            break :option_token .{ .option = .{
                .kind = .option,
                .name = name,
                .raw_name = raw_name,
                .index = option.index,
                .value = value,
                .inline_value = if (value != null) option.inline_value else null,
            } };
        },
        .positional => |positional| .{ .positional = .{
            .kind = .positional,
            .index = positional.index,
            .value = try bun.bindgen.DOMString.fromTextView(positional.value),
        } },
        .option_terminator => |terminator| .{ .option_terminator = .{
            .kind = .option_terminator,
            .index = terminator.index,
        } },
    };
}

fn finishValues(state: *const ParseArgsState) bun.OOM!ParseArgsOutputValues {
    var entries = try ParseArgsOutputValues.Builder.init(state.values.items.len);
    errdefer entries.deinit();
    for (state.values.items) |stored| {
        var key = try bun.bindgen.DOMString.fromTextView(stored.name);
        errdefer key.deinit();
        entries.appendOwned(.{ .key = key, .value = try outputValue(stored.value) });
    }
    return entries.finish();
}

fn stringSequence(
    comptime Sequence: type,
    values: []const TextView,
) bun.OOM!Sequence {
    return Sequence.fromMappedSlice(values, bun.bindgen.DOMString.fromTextView);
}

fn finishTokens(state: *const ParseArgsState) bun.OOM!ParseArgsOutputTokens {
    return ParseArgsOutputTokens.fromMappedSlice(state.tokens.items, outputToken);
}

fn finishMissingDefaults(state: *const ParseArgsState) bun.OOM!ParseArgsMissingDefaults {
    var names: std.ArrayListUnmanaged(TextView) = .empty;
    for (state.option_defs) |option| {
        if (option.has_default and
            !option.long_name.eqlBytes("__proto__") and
            findStoredValue(state.values.items, option.long_name) == null)
        {
            try names.append(state.allocator, option.long_name);
        }
    }
    return stringSequence(ParseArgsMissingDefaults, names.items);
}

fn finishResult(state: *const ParseArgsState) bun.OOM!ParseArgsResult {
    var values = try finishValues(state);
    errdefer values.deinit();
    var positionals = try stringSequence(ParseArgsOutputPositionals, state.positionals.items);
    errdefer positionals.deinit();
    var tokens: ?ParseArgsOutputTokens = if (state.return_tokens) try finishTokens(state) else null;
    errdefer if (tokens) |*value| value.deinit();
    var missing_defaults = try finishMissingDefaults(state);
    errdefer missing_defaults.deinit();
    return .{
        .values = values,
        .positionals = positionals,
        .tokens = tokens,
        .missing_defaults = missing_defaults,
    };
}

pub fn parseArgs(
    context: ParseArgsContext,
    arguments: bun.bindgen.Args(ParseArgsSchema),
) bun.bindgen.CallError(ParseArgsSchema)!ParseArgsResult {
    var arena = std.heap.ArenaAllocator.init(bun.default_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const config = arguments.config;

    var configured_args: std.ArrayListUnmanaged(TextView) = .empty;
    if (config) |value| if (value.args) |input| {
        try configured_args.ensureTotalCapacity(allocator, input.len());
        for (0..input.len()) |index| configured_args.appendAssumeCapacity(bindingText(input.at(index).?));
    };

    const strict = if (config) |value| value.strict else true;
    const allow_positionals = if (config) |value| value.allow_positionals orelse !strict else !strict;
    const return_tokens = if (config) |value| value.tokens else false;
    const allow_negative = if (config) |value| value.allow_negative else false;
    const option_defs = if (config) |value| if (value.options) |options|
        try parseOptionDefinitions(context, options, allocator)
    else
        &.{} else &.{};

    log("Phase 1+2: tokenize args (args.len={d})", .{configured_args.items.len});
    var state = ParseArgsState{
        .context = context,
        .allocator = allocator,
        .option_defs = option_defs,
        .allow_positionals = allow_positionals,
        .strict = strict,
        .allow_negative = allow_negative,
        .return_tokens = return_tokens,
    };
    try tokenizeArgs(&state, configured_args.items, option_defs);
    return finishResult(&state);
}

const std = @import("std");

const utils = @import("./parse_args_utils.zig");
const OptionDefinition = utils.OptionDefinition;
const OptionValueType = utils.OptionValueType;
const classifyToken = utils.classifyToken;
const findOptionByShortName = utils.findOptionByShortName;
const isOptionLikeValue = utils.isOptionLikeValue;

const bun = @import("bun");
const TextView = bun.TextView;

const NodeUtilBindings = bun.bindgen.Module("NodeUtil");
const ParseArgsSchema = NodeUtilBindings.function("parseArgs");
const ParseArgsContext = bun.bindgen.CallContext(ParseArgsSchema);
const ParseArgsResult = bun.bindgen.Return(ParseArgsSchema);
const ParseArgsOutputValues = @FieldType(ParseArgsResult, "values");
const ParseArgsOutputValue = @FieldType(ParseArgsOutputValues.Entry, "value");
const ParseArgsOutputMultiple = @FieldType(ParseArgsOutputValue, "multiple");
const ParseArgsOutputScalar = ParseArgsOutputMultiple.Element;
const ParseArgsOutputPositionals = @FieldType(ParseArgsResult, "positionals");
const ParseArgsOutputTokens = @typeInfo(@FieldType(ParseArgsResult, "tokens")).optional.child;
const ParseArgsOutputToken = ParseArgsOutputTokens.Element;
const ParseArgsMissingDefaults = @FieldType(ParseArgsResult, "missing_defaults");
const ParseArgsBinding = bun.bindgen.Fn(ParseArgsSchema, parseArgs);

comptime {
    _ = ParseArgsBinding;
}
