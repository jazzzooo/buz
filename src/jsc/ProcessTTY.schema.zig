const b = @import("bindgen_schema");
const archetypes = @import("binding_schema_archetypes");

const tty_wrap_value = b.brandedValueWithBrand(b.cppBrand("ProcessTTYWrapValue", .{
    .symbol = "Bun::isTTYWrapObject",
    .header = "ProcessBindingTTYWrap.h",
}, "object"), .{
    .error_kind = .type,
    .expectation = "a TTYWrapObject",
});
const tty_wrap_constructor_value = b.brandedValueWithBrand(b.cppBrand("ProcessTTYWrapConstructorValue", .{
    .symbol = "Bun::isTTYWrapConstructor",
    .header = "ProcessBindingTTYWrap.h",
}, "Function"), .{
    .error_kind = .type,
    .expectation = "the TTYWrap constructor",
});
fn ttyWrapReceiver(comptime name: []const u8) b.Type {
    _ = name;
    return tty_wrap_value;
}

fn method(comptime name: []const u8, comptime arguments: anytype, comptime result: b.Type, comptime length: u16) b.Function {
    return b.function(name, arguments, result, .{
        .backend = .cpp,
        .length = length,
        .profile = .exact,
        .this_value_type = ttyWrapReceiver(name),
    });
}

const functions = .{
    b.function(
        "ttyWrapConstructorCall",
        .{},
        b.none,
        .{ .backend = .cpp, .length = 1, .profile = .exact },
    ),
    b.function(
        "ttyWrapConstructorConstruct",
        .{b.argument("fd", b.int32, .{
            .presence = .optional,
            .missing = .omitted,
            .integer_conversion = .coerce,
        })},
        tty_wrap_value,
        .{ .backend = .cpp, .length = 1, .profile = .exact, .callee_value_type = tty_wrap_constructor_value },
    ),
    b.function(
        "constructTTYWrapConstructor",
        .{},
        tty_wrap_constructor_value,
        .{
            .backend = .cpp,
            .length = 0,
            .profile = .exact,
            .this_value_type = b.js_object,
        },
    ),
    b.function(
        "isatty",
        .{b.argument("fd", b.int32, .{ .presence = .optional, .missing = .omitted })},
        b.boolean,
        .{ .backend = .cpp, .length = 1, .profile = .webidl },
    ),
    b.function(
        "setMode",
        .{
            archetypes.fileDescriptor("fd"),
            archetypes.truthyBoolean("mode", .{}),
        },
        b.int32,
        .{ .backend = .cpp, .length = 2, .profile = .node },
    ),
    method("wrapSetMode", .{archetypes.truthyBoolean("mode", .{})}, b.int32, 0),
    method("wrapGetWindowSize", .{b.argument("array", b.js_array, .{})}, b.boolean, 1),
    b.function(
        "getWindowSize",
        .{ archetypes.fileDescriptor("fd"), b.argument("array", b.js_array, .{}) },
        b.boolean,
        .{ .backend = .cpp, .length = 0, .profile = .node },
    ),
};

const native_exports = .{
    b.nativeExport("enableConsoleControlHandler", .{}, b.none),
    b.nativeExport("setModeNative", .{
        b.argument("fd", b.int32, .{}),
        b.argument("mode", b.int32, .{}),
    }, b.int32),
    b.nativeExport("outputStdioIsTTY", .{b.argument("fd", b.int32, .{})}, b.boolean),
};

pub const schema = b.moduleWithDeclarations("ProcessTTY", functions, .{}, .{}, native_exports);
