pub const FallbackEntryPoint = struct {
    code_buffer: [8192]u8 = undefined,
    path_buffer: bun.PathBuffer = undefined,
    source: logger.Source = undefined,

    pub fn generate(
        entry: *FallbackEntryPoint,
        input_path: string,
        comptime TranspilerType: type,
        transpiler: *TranspilerType,
    ) !void {
        // This is *extremely* naive.
        // The basic idea here is this:
        // --
        // import * as EntryPoint from 'entry-point';
        // import boot from 'framework';
        // boot(EntryPoint);
        // --
        // We go through the steps of printing the code -- only to then parse/transpile it because
        // we want it to go through the linker and the rest of the transpilation process

        const disable_css_imports = transpiler.options.framework.?.client_css_in_js != .auto_onimportcss;

        var code: string = undefined;

        if (disable_css_imports) {
            const fmt =
                \\globalThis.Bun_disableCSSImports = true;
                \\import boot from '{s}';
                \\boot(globalThis.__BUN_DATA__);
            ;

            const args = .{
                input_path,
            };

            const count = std.fmt.count(fmt, args);
            if (count < entry.code_buffer.len) {
                code = try std.fmt.bufPrint(&entry.code_buffer, fmt, args);
            } else {
                code = try std.fmt.allocPrint(transpiler.allocator, fmt, args);
            }
        } else {
            const fmt =
                \\import boot from '{s}';
                \\boot(globalThis.__BUN_DATA__);
            ;

            const args = .{
                input_path,
            };

            const count = std.fmt.count(fmt, args);
            if (count < entry.code_buffer.len) {
                code = try std.fmt.bufPrint(&entry.code_buffer, fmt, args);
            } else {
                code = try std.fmt.allocPrint(transpiler.allocator, fmt, args);
            }
        }

        entry.source = logger.Source.initPathString(input_path, code);
        entry.source.path.namespace = "fallback-entry";
    }
};

pub const ClientEntryPoint = struct {
    code_buffer: [8192]u8 = undefined,
    path_buffer: bun.PathBuffer = undefined,
    source: logger.Source = undefined,

    pub fn generateEntryPointPath(outbuffer: []u8, original_path: string) !string {
        const filename = std.fs.path.basename(original_path);
        const extension = std.fs.path.extension(filename);
        const stem = filename[0 .. filename.len - extension.len];
        const generated_filename = std.fmt.bufPrint(&entry_path_filename_buf, "{s}.entry{s}", .{ stem, extension }) catch unreachable;

        if (std.fs.path.dirname(original_path)) |dir| {
            return std.mem.print(outbuffer, "{f}", .{std.fs.path.fmtJoin(&.{ dir, generated_filename })});
        }

        return std.fmt.bufPrint(outbuffer, "{s}", .{generated_filename}) catch unreachable;
    }

    threadlocal var entry_path_filename_buf: bun.PathBuffer = undefined;

    pub fn generate(entry: *ClientEntryPoint, comptime TranspilerType: type, transpiler: *TranspilerType, original_path: string, client: string) !void {

        // This is *extremely* naive.
        // The basic idea here is this:
        // --
        // import * as EntryPoint from 'entry-point';
        // import boot from 'framework';
        // boot(EntryPoint);
        // --
        // We go through the steps of printing the code -- only to then parse/transpile it because
        // we want it to go through the linker and the rest of the transpilation process

        const disable_css_imports = transpiler.options.framework.?.client_css_in_js != .auto_onimportcss;

        var code: string = undefined;

        if (disable_css_imports) {
            code = try std.fmt.bufPrint(
                &entry.code_buffer,
                \\globalThis.Bun_disableCSSImports = true;
                \\import boot from '{s}';
                \\import * as EntryPoint from '{s}';
                \\boot(EntryPoint);
            ,
                .{
                    client,
                    original_path,
                },
            );
        } else {
            code = try std.fmt.bufPrint(
                &entry.code_buffer,
                \\import boot from '{s}';
                \\if ('setLoaded' in boot) boot.setLoaded(loaded);
                \\import * as EntryPoint from '{s}';
                \\boot(EntryPoint);
            ,
                .{
                    client,
                    original_path,
                },
            );
        }

        entry.source = logger.Source.initPathString(try generateEntryPointPath(&entry.path_buffer, original_path), code);
        entry.source.path.namespace = "client-entry";
    }
};

pub const ServerEntryPoint = struct {
    /// The generated wrapper source for `bun:main`. Always a valid slice
    /// (either empty or owned by `bun.default_allocator`) so readers never
    /// see `undefined` memory regardless of the `generated` flag's state.
    contents: []const u8 = "",
    generated: bool = false,

    pub fn deinit(entry: *ServerEntryPoint) void {
        if (entry.contents.len > 0) {
            bun.default_allocator.free(entry.contents);
        }
        entry.contents = "";
        entry.generated = false;
    }

    pub fn generate(
        entry: *ServerEntryPoint,
        is_hot_reload_enabled: bool,
        path_to_use: string,
    ) !void {
        // Use the global allocator so this buffer's lifetime is decoupled
        // from whichever arena the caller's VM happens to be using; the
        // slice is read later from `getHardcodedModule` which outlives any
        // per-transpile arena.
        const allocator = bun.default_allocator;
        const code = brk: {
            if (is_hot_reload_enabled) {
                break :brk try std.fmt.allocPrint(
                    allocator,
                    \\// @bun
                    \\import * as start from '{f}';
                    \\var hmrSymbol = Symbol("BunServerHMR");
                    \\var entryNamespace = start;
                    \\function isServerConfig(def) {{
                    \\   return def && def !== globalThis && (typeof def.fetch === 'function' || def.app != undefined) && typeof def.stop !== 'function';
                    \\}}
                    \\if (typeof entryNamespace?.then === 'function') {{
                    \\   entryNamespace = entryNamespace.then((entryNamespace) => {{
                    \\      var def = entryNamespace?.default;
                    \\      if (isServerConfig(def))  {{
                    \\        var server = globalThis[hmrSymbol];
                    \\        if (server) {{
                    \\           server.reload(def);
                    \\           console.debug(`Reloaded ${{server.development ? 'development ' : ''}}server: ${{server.protocol}}://${{server.hostname}}:${{server.port}}`);
                    \\        }} else {{
                    \\           server = globalThis[hmrSymbol] = Bun.serve(def);
                    \\           console.debug(`Started ${{server.development ? 'development ' : ''}}server: ${{server.protocol}}://${{server.hostname}}:${{server.port}}`);
                    \\        }}
                    \\      }}
                    \\   }}, reportError);
                    \\}} else if (isServerConfig(entryNamespace?.default)) {{
                    \\   var server = globalThis[hmrSymbol];
                    \\   if (server) {{
                    \\      server.reload(entryNamespace.default);
                    \\      console.debug(`Reloaded ${{server.development ? 'development ' : ''}}server: ${{server.protocol}}://${{server.hostname}}:${{server.port}}`);
                    \\   }} else {{
                    \\      server = globalThis[hmrSymbol] = Bun.serve(entryNamespace.default);
                    \\      console.debug(`Started ${{server.development ? 'development ' : ''}}server: ${{server.protocol}}://${{server.hostname}}:${{server.port}}`);
                    \\   }}
                    \\}}
                    \\
                ,
                    .{
                        strings.formatEscapes(path_to_use, .{ .quote_char = '\'' }),
                    },
                );
            }
            break :brk try std.fmt.allocPrint(
                allocator,
                \\// @bun
                \\import * as start from "{f}";
                \\var entryNamespace = start;
                \\function isServerConfig(def) {{
                \\   return def && def !== globalThis && (typeof def.fetch === 'function' || def.app != undefined) && typeof def.stop !== 'function';
                \\}}
                \\if (typeof entryNamespace?.then === 'function') {{
                \\   entryNamespace = entryNamespace.then((entryNamespace) => {{
                \\      if (isServerConfig(entryNamespace?.default))  {{
                \\        const server = Bun.serve(entryNamespace.default);
                \\        console.debug(`Started ${{server.development ? 'development ' : ''}}server: ${{server.protocol}}://${{server.hostname}}:${{server.port}}`);
                \\      }}
                \\   }}, reportError);
                \\}} else if (isServerConfig(entryNamespace?.default)) {{
                \\   const server = Bun.serve(entryNamespace.default);
                \\   console.debug(`Started ${{server.development ? 'development ' : ''}}server: ${{server.protocol}}://${{server.hostname}}:${{server.port}}`);
                \\}}
                \\
            ,
                .{
                    strings.formatEscapes(path_to_use, .{ .quote_char = '"' }),
                },
            );
        };

        // Free the previous buffer on regenerate (hot reload) instead of
        // leaking it. `contents` is either "" or a prior allocPrint result.
        if (entry.contents.len > 0) {
            allocator.free(entry.contents);
        }
        entry.contents = code;
        entry.generated = true;
    }
};

const string = []const u8;

const std = @import("std");

const bun = @import("bun");
const logger = bun.logger;
const strings = bun.strings;
