const PluginResolver = @This();
pub const Context = bun.bindgen.NativeCallbackContext(.vm);

pub const Target = enum {
    browser,
    bun,
    node,
};

context: Context,
resolve_fn: *const fn (
    context: Context,
    specifier: []const u8,
    importer: []const u8,
    log: *logger.Log,
    loc: logger.Loc,
    target: Target,
) bun.JSError!?Fs.Path,

pub fn resolve(
    this: PluginResolver,
    specifier: []const u8,
    importer: []const u8,
    log: *logger.Log,
    loc: logger.Loc,
    target: Target,
) bun.JSError!?Fs.Path {
    return this.resolve_fn(this.context, specifier, importer, log, loc, target);
}

pub fn extractNamespace(specifier: []const u8) []const u8 {
    const colon = strings.indexOfChar(specifier, ':') orelse return "";
    if (Environment.isWindows and
        colon == 1 and
        specifier.len > 3 and
        std.fs.path.PathType.windows.isSep(u8, specifier[2]) and
        ((specifier[0] > 'a' and specifier[0] < 'z') or (specifier[0] > 'A' and specifier[0] < 'Z')))
        return "";
    return specifier[0..colon];
}

pub fn couldResolve(specifier: []const u8) bool {
    if (strings.lastIndexOfChar(specifier, '.')) |last_dot| {
        const ext = specifier[last_dot + 1 ..];
        if (ext.len > 0 and ((ext[0] >= 'a' and ext[0] <= 'z') or (ext[0] >= 'A' and ext[0] <= 'Z') or ext[0] > 127))
            return true;
    }
    return !std.fs.path.isAbsolute(specifier) and strings.containsChar(specifier, ':');
}

const std = @import("std");

const bun = @import("bun");
const Environment = bun.Environment;
const Fs = bun.fs;
const logger = bun.logger;
const strings = bun.strings;
