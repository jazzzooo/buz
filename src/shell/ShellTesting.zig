pub const TestingAPIs = struct {
    pub fn disabledOnThisPlatform(
        _: bun.bindgen.CallContext(ShellDisabledOnThisPlatformSchema),
        args: bun.bindgen.Args(ShellDisabledOnThisPlatformSchema),
    ) bun.JSError!bool {
        if (comptime bun.Environment.isWindows) return false;

        const utf8str = try args.name.toUTF8(bun.default_allocator);
        defer utf8str.deinit();

        inline for (Interpreter.Builtin.Kind.DISABLED_ON_POSIX) |disabled| {
            if (bun.strings.eqlComptime(utf8str.byteSlice(), @tagName(disabled))) return true;
        }
        return false;
    }

    pub fn shellLex(
        context: bun.bindgen.CallContext(ShellLexSchema),
        args: bun.bindgen.Args(ShellLexSchema),
    ) bun.bindgen.CallError(ShellLexSchema)!bun.bindgen.DOMString {
        return shellLexImpl(context, args.strings, args.values);
    }

    fn shellLexImpl(
        context: bun.bindgen.CallContext(ShellLexSchema),
        string_args: anytype,
        template_args: anytype,
    ) bun.bindgen.CallError(ShellLexSchema)!bun.bindgen.DOMString {
        var arena = std.heap.ArenaAllocator.init(bun.default_allocator);
        defer arena.deinit();

        var stack_alloc_buffer: [4]bun.String = undefined;
        var stack_alloc: std.heap.BufferFirstAllocator = .init(@ptrCast(&stack_alloc_buffer), arena.allocator());
        var jsstrings = try std.array_list.Managed(bun.String).initCapacity(stack_alloc.allocator(), 4);
        defer {
            for (jsstrings.items) |bunstr| bunstr.deref();
            jsstrings.deinit();
        }
        var script = std.array_list.Managed(u8).init(arena.allocator());
        var object_count: u32 = 0;
        try Template.appendCommandFromBinding(context, string_args, template_args, null, &object_count, &jsstrings, &script);

        const lex_result = brk: {
            if (bun.strings.isAllASCII(script.items)) {
                var lexer = shell.LexerAscii.new(arena.allocator(), script.items, jsstrings.items, object_count);
                lexer.lex() catch |err| return Template.failBinding(context, .parse, "failed to lex shell: {s}", .{@errorName(err)});
                break :brk lexer.get_result();
            }
            var lexer = shell.LexerUnicode.new(arena.allocator(), script.items, jsstrings.items, object_count);
            lexer.lex() catch |err| return Template.failBinding(context, .parse, "failed to lex shell: {s}", .{@errorName(err)});
            break :brk lexer.get_result();
        };

        if (lex_result.errors.len > 0) {
            const message = lex_result.combineErrors(arena.allocator());
            return context.fail(.parse, try bun.bindgen.DOMString.fromUTF8(message));
        }

        var test_tokens = try std.array_list.Managed(shell.Test.TestToken).initCapacity(arena.allocator(), lex_result.tokens.len);
        for (lex_result.tokens) |token| try test_tokens.append(shell.Test.TestToken.from_real(token, lex_result.strpool));

        const json = try std.fmt.allocPrint(bun.default_allocator, "{f}", .{std.json.fmt(test_tokens.items, .{})});
        defer bun.default_allocator.free(json);
        return bun.bindgen.DOMString.fromUTF8(json);
    }

    pub fn shellParse(
        context: bun.bindgen.CallContext(ShellParseSchema),
        args: bun.bindgen.Args(ShellParseSchema),
    ) bun.bindgen.CallError(ShellParseSchema)!bun.bindgen.DOMString {
        return shellParseImpl(context, args.strings, args.values);
    }

    fn shellParseImpl(
        context: bun.bindgen.CallContext(ShellParseSchema),
        string_args: anytype,
        template_args: anytype,
    ) bun.bindgen.CallError(ShellParseSchema)!bun.bindgen.DOMString {
        var arena = bun.ArenaAllocator.init(bun.default_allocator);
        defer arena.deinit();

        var stack_alloc_buffer: [4]bun.String = undefined;
        var stack_alloc: std.heap.BufferFirstAllocator = .init(@ptrCast(&stack_alloc_buffer), arena.allocator());
        var jsstrings = try std.array_list.Managed(bun.String).initCapacity(stack_alloc.allocator(), 4);
        defer {
            for (jsstrings.items) |bunstr| bunstr.deref();
            jsstrings.deinit();
        }
        var script = std.array_list.Managed(u8).init(arena.allocator());
        var object_count: u32 = 0;
        try Template.appendCommandFromBinding(context, string_args, template_args, null, &object_count, &jsstrings, &script);

        var parser: ?shell.Parser = null;
        var lex_result: ?shell.LexResult = null;
        const script_ast = Interpreter.parse(arena.allocator(), script.items, object_count, jsstrings.items, &parser, &lex_result) catch |err| {
            if (err == shell.ParseError.Lex) {
                if (bun.Environment.allow_assert) assert(lex_result != null);
                const message = lex_result.?.combineErrors(arena.allocator());
                return context.fail(.parse, try bun.bindgen.DOMString.fromUTF8(message));
            }
            if (parser) |*parsed| return context.fail(.parse, try bun.bindgen.DOMString.fromUTF8(parsed.combineErrors()));
            return Template.failBinding(context, .parse, "failed to lex/parse shell: {s}", .{@errorName(err)});
        };

        const json = try std.fmt.allocPrint(bun.default_allocator, "{f}", .{std.json.fmt(script_ast, .{})});
        defer bun.default_allocator.free(json);
        return bun.bindgen.DOMString.fromUTF8(json);
    }
};

const std = @import("std");
const bun = @import("bun");
const assert = bun.assert;
const shell = bun.shell;
const Interpreter = shell.Interpreter;
const Template = @import("./ShellTemplate.zig");

const InternalTestingBindings = bun.bindgen.Module("InternalTesting");
const ShellDisabledOnThisPlatformSchema = InternalTestingBindings.function("shellDisabledOnThisPlatform");
const ShellLexSchema = InternalTestingBindings.function("shellLex");
const ShellParseSchema = InternalTestingBindings.function("shellParse");
const ShellDisabledOnThisPlatformBinding = bun.bindgen.Fn(ShellDisabledOnThisPlatformSchema, TestingAPIs.disabledOnThisPlatform);
const ShellLexBinding = bun.bindgen.Fn(ShellLexSchema, TestingAPIs.shellLex);
const ShellParseBinding = bun.bindgen.Fn(ShellParseSchema, TestingAPIs.shellParse);

comptime {
    _ = ShellDisabledOnThisPlatformBinding;
    _ = ShellLexBinding;
    _ = ShellParseBinding;
}
