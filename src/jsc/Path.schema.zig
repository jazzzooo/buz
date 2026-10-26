const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const path_string = b.coerceStringWithOptions(b.dom_string, .{
    .input = .string_or_boxed,
    .type_error_format = .property_typeof,
});

const path_parsed_object = b.dictionary("PathParsedObject", .{
    b.dictionaryField("root", b.dom_string, .{ .required = true }),
    b.dictionaryField("dir", b.dom_string, .{ .required = true }),
    b.dictionaryField("base", b.dom_string, .{ .required = true }),
    b.dictionaryField("ext", b.dom_string, .{ .required = true }),
    b.dictionaryField("name", b.dom_string, .{ .required = true }),
});

const path_errors = b.domainErrors(.{b.systemError("system")});

fn unaryPathFunction(comptime name: []const u8, comptime return_type: b.Type) b.Function {
    return b.function(
        name,
        .{b.argument("path", path_string, .{})},
        return_type,
        .{ .backend = .zig, .length = 1, .profile = .node },
    );
}

fn basenameFunction(comptime name: []const u8) b.Function {
    return b.function(
        name,
        .{
            b.argument("path", path_string, .{}),
            b.argument("suffix", path_string, .{ .presence = .optional, .missing = .undefined }),
        },
        b.dom_string,
        .{ .backend = .zig, .length = 2, .profile = .node },
    );
}

fn joinFunction(comptime name: []const u8) b.Function {
    return b.function(
        name,
        .{b.rest("path", path_string)},
        b.dom_string,
        .{ .backend = .zig, .length = 0, .profile = .node },
    );
}

fn relativeFunction(comptime name: []const u8) b.Function {
    return b.function(
        name,
        .{
            b.argument("from", path_string, .{}),
            b.argument("to", path_string, .{}),
        },
        b.dom_string,
        .{ .backend = .zig, .errors = path_errors, .length = 2, .profile = .node },
    );
}

fn resolveFunction(comptime name: []const u8) b.Function {
    return b.function(
        name,
        .{b.lazyRest("paths", path_string, "path.resolve coerces operands right-to-left and stops once an absolute root is found")},
        b.dom_string,
        .{ .backend = .zig, .errors = path_errors, .length = 0, .profile = .node },
    );
}

fn namespacedPathFunction(comptime name: []const u8) b.Function {
    return b.function(
        name,
        .{b.argument("path", path_string, .{})},
        b.dom_string,
        .{ .backend = .zig, .errors = path_errors, .length = 1, .profile = .node },
    );
}

const functions = .{
    basenameFunction("basenamePosix"),
    basenameFunction("basenameWindows"),
    unaryPathFunction("dirnamePosix", b.dom_string),
    unaryPathFunction("dirnameWindows", b.dom_string),
    unaryPathFunction("extnamePosix", b.dom_string),
    unaryPathFunction("extnameWindows", b.dom_string),
    unaryPathFunction("isAbsolutePosix", b.boolean),
    unaryPathFunction("isAbsoluteWindows", b.boolean),
    joinFunction("joinPosix"),
    joinFunction("joinWindows"),
    unaryPathFunction("normalizePosix", b.dom_string),
    unaryPathFunction("normalizeWindows", b.dom_string),
    unaryPathFunction("parsePosix", path_parsed_object),
    unaryPathFunction("parseWindows", path_parsed_object),
    relativeFunction("relativePosix"),
    relativeFunction("relativeWindows"),
    resolveFunction("resolvePosix"),
    resolveFunction("resolveWindows"),
    namespacedPathFunction("toNamespacedPathWindows"),
};

fn nativeDirname(comptime name: []const u8) b.NativeExport {
    return b.nativeExportWithOptions(name, .{b.argument("path", b.dom_string, .{})}, b.dom_string, .current_realm_throwing);
}

const native_exports = .{
    nativeDirname("dirnamePosix"),
    nativeDirname("dirnameWindows"),
    b.nativeExportWithOptions("resolvePathFromCwd", .{b.argument("input", b.dom_string, .{})}, b.dom_string, .current_realm_throwing),
    b.nativeExportWithOptions("nodePathJoinCurrentPlatform", .{
        b.argument("lhs", b.dom_string, .{}),
        b.argument("rhs", b.dom_string, .{}),
    }, b.dom_string, .current_realm_throwing),
    b.nativeExportWithOptions("resolverNodeModulePaths", .{
        b.argument("path", b.dom_string, .{}),
        b.argument("useDirname", b.boolean, .{}),
    }, archetypes.dom_strings, .current_realm_throwing),
};

pub const schema = b.moduleWithDeclarations("Path", functions, .{}, .{}, native_exports);
