const Syntax = struct {
    bindgen_state: bindgen.ClassState = .{},
    args: ?bindgen.OwnedNative(ShellArgs, .any),
    memory_size: std.atomic.Value(usize),

    fn init(args: *ShellArgs) Syntax {
        return .{
            .args = .init(args),
            .memory_size = .init(@sizeOf(Syntax) + args.memoryCost()),
        };
    }

    pub fn memoryUsage(this: *const Syntax, _: bindgen.MemoryUsageContext(.any)) usize {
        return this.memory_size.load(.monotonic);
    }

    fn take(this: *Syntax) ?*ShellArgs {
        const args = if (this.args) |*owned| owned.take() else return null;
        this.args = null;
        this.memory_size.store(@sizeOf(Syntax), .monotonic);
        return args;
    }

    pub fn destroy(this: *Syntax, _: bindgen.SweepContext) void {
        if (this.args) |*args| args.deinit();
        bun.destroy(this);
    }

    const Schema = bindgen.Module("ParsedShellScript").class("ShellSyntax");
    const Binding = bindgen.Class(Schema, Syntax);
};

pub const ParsedShellScript = struct {
    const Self = @This();

    bindgen_state: bindgen.ClassState = .{},
    export_env: ExportEnv = .empty,
    quiet: bool = false,
    cwd: ?bindgen.DOMString = null,
    shell_values: ?bindgen.OwnedNative(ShellValue.List, .vm) = null,

    fn computeEstimatedSizeForGC(this: *const Self) usize {
        var size: usize = @sizeOf(Self);
        if (this.export_env.getOptional()) |env| size += @sizeOf(EnvMap) + env.memoryCost();
        if (this.cwd) |cwd| {
            if (cwd.impl) |impl| size += impl.byteLength();
        }
        if (this.shell_values) |values| size += values.get().memoryCost();
        return size;
    }

    pub fn memoryUsage(this: *const Self, _: bindgen.MemoryUsageContext(.vm)) usize {
        return this.computeEstimatedSizeForGC();
    }

    pub const Handle = Binding.Handle;

    pub const Taken = struct {
        args: *ShellArgs,
        quiet: bool,
        cwd: ?bindgen.DOMString,
        export_env: ?EnvMap,
        shell_values: *ShellValue.List,
    };

    pub fn take(this: *Self, wrapper: *const bindgen.ClassRef(ParsedShellScriptSchema)) bun.JSError!?Taken {
        var syntax = (try SyntaxSlot.getOwned(wrapper)) orelse return null;
        defer syntax.deinit();
        const args = syntax.get(Syntax).take() orelse return null;
        Binding.CachedSlotInvalidator("syntax").clearOwned(wrapper);
        const shell_values = if (this.shell_values) |*owned| owned.take() else unreachable;
        const taken: Taken = .{
            .args = args,
            .quiet = this.quiet,
            .cwd = this.cwd,
            .export_env = if (this.export_env.takeOptional()) |env| value: {
                const value = env.*;
                bun.destroy(env);
                break :value value;
            } else null,
            .shell_values = shell_values,
        };

        this.cwd = null;
        this.shell_values = null;
        return taken;
    }

    pub fn destroy(this: *Self) void {
        this.export_env.deinit();
        if (this.cwd) |*cwd| cwd.deinit();
        if (this.shell_values) |*values| values.deinit();
        bun.destroy(this);
    }

    pub fn setCwd(
        this: *Self,
        context: bindgen.CallContext(SetCwdSchema),
        args_: bindgen.Args(SetCwdSchema),
    ) bun.JSError!void {
        _ = context;
        if (this.cwd) |*previous| previous.deinit();
        this.cwd = args_.cwd.toOwned();
    }

    pub fn setQuiet(
        this: *Self,
        _: bindgen.CallContext(SetQuietSchema),
        args_: bindgen.Args(SetQuietSchema),
    ) bun.JSError!void {
        this.quiet = args_.quiet orelse false;
    }

    pub fn setEnv(
        this: *Self,
        context: bindgen.CallContext(SetEnvSchema),
        args_: bindgen.Args(SetEnvSchema),
    ) bun.JSError!void {
        _ = context;

        var env: EnvMap = EnvMap.init(bun.default_allocator);
        errdefer env.deinit();
        env.ensureTotalCapacity(args_.env.len());

        for (0..args_.env.len()) |index| {
            const entry = args_.env.at(index).?;
            const value = entry.value orelse continue;
            var key_utf8 = try entry.key.toUTF8(bun.default_allocator);
            const keyslice = try key_utf8.intoOwnedSlice(bun.default_allocator);
            errdefer bun.default_allocator.free(keyslice);
            var value_utf8 = try value.toUTF8(bun.default_allocator);
            const slice = try value_utf8.intoOwnedSlice(bun.default_allocator);
            const keyref = EnvStr.initRefCounted(keyslice);
            defer keyref.deref();
            const valueref = EnvStr.initRefCounted(slice);
            defer valueref.deref();

            env.insert(keyref, valueref);
        }
        this.export_env.deinit();
        this.export_env = .init(bun.new(EnvMap, env));
    }

    fn deinitExportEnv(env: *EnvMap) void {
        env.deinit();
        bun.destroy(env);
    }

    const ExportEnv = bindgen.OwnedNativeWithDestructor(EnvMap, deinitExportEnv, .any);
    const ParsedShellScriptBindingModule = bindgen.Module("ParsedShellScript");
    const ParsedShellScriptSchema = ParsedShellScriptBindingModule.class("ParsedShellScript");
    pub const Binding = bindgen.Class(ParsedShellScriptSchema, Self);
    const SyntaxSlot = Binding.CachedClassRefSlot("syntax");
    const SetCwdSchema = ParsedShellScriptSchema.member("setCwd");
    const SetEnvSchema = ParsedShellScriptSchema.member("setEnv");
    const SetQuietSchema = ParsedShellScriptSchema.member("setQuiet");

    comptime {
        _ = Binding;
    }
};

pub fn createParsedShellScript(
    context: bindgen.CallContext(CreateParsedShellScriptSchema),
    args: bindgen.Args(CreateParsedShellScriptSchema),
) bindgen.CallError(CreateParsedShellScriptSchema)!bindgen.Return(CreateParsedShellScriptSchema) {
    return createParsedShellScriptImpl(context, args.stringArgs, args.templateArgs);
}

fn createParsedShellScriptImpl(
    context: bindgen.CallContext(CreateParsedShellScriptSchema),
    string_args: anytype,
    template_args: anytype,
) bindgen.CallError(CreateParsedShellScriptSchema)!bindgen.Return(CreateParsedShellScriptSchema) {
    var shargs = ShellArgs.init();
    var needs_to_free_shargs = true;
    defer if (needs_to_free_shargs) shargs.deinit();

    var shell_values = std.array_list.Managed(ShellValue.Value).init(bun.default_allocator);
    errdefer {
        for (shell_values.items) |*value| value.deinit();
        shell_values.deinit();
    }

    {
        var stack_alloc_buffer: [4]bun.String = undefined;
        var stack_alloc: std.heap.BufferFirstAllocator = .init(@ptrCast(&stack_alloc_buffer), shargs.arena_allocator());
        var jsstrings = try std.array_list.Managed(bun.String).initCapacity(stack_alloc.allocator(), 4);
        defer {
            for (jsstrings.items) |bunstr| bunstr.deref();
            jsstrings.deinit();
        }

        var script = std.array_list.Managed(u8).init(shargs.arena_allocator());
        var object_count: u32 = 0;
        try Template.appendCommandFromBinding(context, string_args, template_args, &shell_values, &object_count, &jsstrings, &script);

        var parser: ?shell.Parser = null;
        var lex_result: ?shell.LexResult = null;
        const script_ast = Interpreter.parse(
            shargs.arena_allocator(),
            script.items,
            object_count,
            jsstrings.items,
            &parser,
            &lex_result,
        ) catch |err| {
            if (err == shell.ParseError.Lex) {
                assert(lex_result != null);
                const message = lex_result.?.combineErrors(shargs.arena_allocator());
                return context.fail(.parse, try bindgen.DOMString.fromUTF8(message));
            }

            if (parser) |*parsed| {
                if (bun.Environment.allow_assert) assert(parsed.errors.items.len > 0);
                return context.fail(.parse, try bindgen.DOMString.fromUTF8(parsed.combineErrors()));
            }

            return context.fail(.parse, try bindgen.DOMString.fromUTF8(@errorName(err)));
        };

        shargs.script_ast = script_ast;
    }

    const owned_shell_values = try ShellValue.List.create(shell_values);
    shell_values = .init(bun.default_allocator);
    defer if (needs_to_free_shargs) owned_shell_values.destroy();

    const syntax = try bun.default_allocator.create(Syntax);
    syntax.* = Syntax.init(shargs);
    needs_to_free_shargs = false;
    var values_owner = bindgen.OwnedNative(ShellValue.List, .vm).init(owned_shell_values);
    defer values_owner.deinit();
    const global = context.viewToken().globalObject();
    var syntax_ref = try Syntax.Binding.adoptNativeRef(syntax, global);
    defer syntax_ref.deinit();

    const parsed_shell_script = try bun.default_allocator.create(ParsedShellScript);
    parsed_shell_script.* = .{ .shell_values = .init(values_owner.take()) };
    const reference = try ParsedShellScript.Binding.adoptResult(parsed_shell_script, context);
    ParsedShellScript.SyntaxSlot.setOnOwned(&reference, &syntax_ref);

    bun.analytics.Features.shell += 1;
    return reference;
}

const std = @import("std");
const interpreter = @import("./interpreter.zig");
const ShellArgs = interpreter.ShellArgs;
const ShellValue = @import("./ShellValue.zig");
const Template = @import("./ShellTemplate.zig");
const EnvMap = @import("./EnvMap.zig");
const EnvStr = @import("./EnvStr.zig").EnvStr;

const bun = @import("bun");
const assert = bun.assert;
const bindgen = bun.bindgen;
const shell = bun.shell;
const Interpreter = shell.Interpreter;

const BunObjectBindingModule = bindgen.Module("BunObject");
const CreateParsedShellScriptSchema = BunObjectBindingModule.function("createParsedShellScript");
const CreateParsedShellScriptBinding = bindgen.Fn(CreateParsedShellScriptSchema, createParsedShellScript);

comptime {
    _ = Syntax.Binding;
    _ = CreateParsedShellScriptBinding;
}
