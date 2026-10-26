//! Test-only engine host functions for `bun.ini`.
//! Kept out of `ini/` so that directory has no JSC references.

pub const IniTestingAPIs = struct {
    pub fn loadNpmrcFromJS(
        context: bun.bindgen.CallContext(LoadNpmrcSchema),
        args: bun.bindgen.Args(LoadNpmrcSchema),
    ) bun.JSError!bun.bindgen.Return(LoadNpmrcSchema) {
        return loadNpmrcWithEnvironment(context.viewToken().globalObject(), args);
    }

    fn loadNpmrcWithEnvironment(
        globalThis: *bun.jsc.JSGlobalObject,
        args: bun.bindgen.Args(LoadNpmrcSchema),
    ) bun.JSError!bun.bindgen.Return(LoadNpmrcSchema) {
        const npmrc_utf8 = try args.contents.toUTF8(bun.default_allocator);
        defer npmrc_utf8.deinit();
        const source = &bun.logger.Source.initPathString("<js>", npmrc_utf8.slice());

        var log = bun.logger.Log.init(bun.default_allocator);
        defer log.deinit();

        var arena = bun.ArenaAllocator.init(bun.default_allocator);
        const allocator = arena.allocator();
        defer arena.deinit();

        const env = if (args.env) |environment| brk: {
            var envmap: bun.DotEnv.Map.HashTable = .empty;
            try envmap.ensureTotalCapacity(allocator, environment.len());

            for (0..environment.len()) |index| {
                const entry = environment.at(index).?;
                const value = entry.value orelse continue;
                var key_utf8 = try entry.key.toUTF8(allocator);
                const keyslice = try key_utf8.intoOwnedSlice(allocator);
                var value_utf8 = try value.toUTF8(allocator);
                const slice = try value_utf8.intoOwnedSlice(allocator);

                envmap.put(allocator, keyslice, .{
                    .value = slice,
                    .conditional = false,
                }) catch return error.OutOfMemory;
            }

            const map = try allocator.create(bun.DotEnv.Map);
            map.* = .{
                .map = envmap,
                .allocator = allocator,
            };

            const env = bun.DotEnv.Loader.init(map, allocator);
            const envstable = try allocator.create(bun.DotEnv.Loader);
            envstable.* = env;
            break :brk envstable;
        } else globalThis.bunVM().transpiler.env;

        const install = try allocator.create(bun.schema.api.BunInstall);
        install.* = std.mem.zeroes(bun.schema.api.BunInstall);
        var configs = std.array_list.Managed(ConfigIterator.Item).init(allocator);
        defer configs.deinit();
        try loadNpmrc(allocator, install, env, ".npmrc", &log, source, &configs);

        const default_registry = install.default_registry;
        var url = try bun.bindgen.DOMString.fromUTF8(if (default_registry) |registry| registry.url else Registry.default_url);
        errdefer url.deinit();
        var token = try bun.bindgen.DOMString.fromUTF8(if (default_registry) |registry| registry.token else "");
        errdefer token.deinit();
        var username = try bun.bindgen.DOMString.fromUTF8(if (default_registry) |registry| registry.username else "");
        errdefer username.deinit();
        var password = try bun.bindgen.DOMString.fromUTF8(if (default_registry) |registry| registry.password else "");
        errdefer password.deinit();
        var email = try bun.bindgen.DOMString.fromUTF8(if (default_registry) |registry| registry.email else "");
        errdefer email.deinit();

        return .{
            .default_registry_url = url,
            .default_registry_token = token,
            .default_registry_username = username,
            .default_registry_password = password,
            .default_registry_email = email,
        };
    }

    pub fn parse(
        context: bun.bindgen.CallContext(ParseIniSchema),
        args: bun.bindgen.Args(ParseIniSchema),
    ) bun.JSError!bun.bindgen.DOMString {
        return parseWithEnvironment(context.viewToken().globalObject(), args);
    }

    fn parseWithEnvironment(
        globalThis: *bun.jsc.JSGlobalObject,
        args: bun.bindgen.Args(ParseIniSchema),
    ) bun.JSError!bun.bindgen.DOMString {
        const utf8str = try args.contents.toUTF8(bun.default_allocator);
        defer utf8str.deinit();

        var parser = Parser.init(bun.default_allocator, "<src>", utf8str.slice(), globalThis.bunVM().transpiler.env);
        defer parser.deinit();

        try parser.parse(parser.arena.allocator());

        const buffer_writer = bun.js_printer.BufferWriter.init(bun.default_allocator);
        var writer = bun.js_printer.BufferPrinter.init(buffer_writer);
        defer writer.ctx.buffer.deinit();
        _ = bun.js_printer.printJSON(
            *bun.js_printer.BufferPrinter,
            &writer,
            parser.out,
            &parser.source,
            .{ .mangled_props = null },
        ) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => unreachable,
        };
        return bun.bindgen.DOMString.fromUTF8(writer.ctx.buffer.slice());
    }
};

const std = @import("std");

const bun = @import("bun");
const Registry = bun.install.Npm.Registry;

const ini = bun.ini;
const ConfigIterator = ini.ConfigIterator;
const Parser = ini.Parser;
const loadNpmrc = ini.loadNpmrc;

const InternalTestingBindings = bun.bindgen.Module("InternalTesting");
const LoadNpmrcSchema = InternalTestingBindings.function("loadNpmrc");
const ParseIniSchema = InternalTestingBindings.function("parseIni");
const LoadNpmrcBinding = bun.bindgen.Fn(LoadNpmrcSchema, IniTestingAPIs.loadNpmrcFromJS);
const ParseIniBinding = bun.bindgen.Fn(ParseIniSchema, IniTestingAPIs.parse);

comptime {
    _ = LoadNpmrcBinding;
    _ = ParseIniBinding;
}
