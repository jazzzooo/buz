//! The binding generator normalizes every schema module into the plain-data IR
//! and renders every artifact from it.
const std = @import("std");
const Io = std.Io;
const ir = @import("bindgen_ir");
const schema = @import("bindgen_schema");
const schemas = @import("binding_schemas");
const normalize = @import("normalize.zig");
const emitter = @import("emitter.zig");
const binding_document = @import("document.zig");

const modules: [schemas.modules.len]schema.Module = schemas.modules;
const source_stems: [schemas.source_stems.len][]const u8 = schemas.source_stems;

const usage =
    \\usage: binding-generator --target <target> --cpp-shards <count> --headers=<dir> --wire=<dir>
    \\                         --typescript=<dir> --cpp=<dir> --ir=<file> --fingerprint=<file>
    \\
;

const EmitOptions = struct {
    target: ir.Target,
    cpp_shards: u32,
    directories: std.enums.EnumArray(emitter.Group, []const u8),
    ir: []const u8,
    fingerprint: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const options = parseEmitOptions(args[1..]) catch |err| return fail(init.io, "{s}: {t}\n{s}", .{ "invalid arguments", err, usage });
    return emit(init, options);
}

fn fail(io: Io, comptime format: []const u8, args: anytype) error{Reported} {
    var stderr = Io.File.stderr().writer(io, &.{});
    stderr.interface.print(format, args) catch {};
    return error.Reported;
}

fn parseEmitOptions(args: []const []const u8) !EmitOptions {
    var target: ?ir.Target = null;
    var cpp_shards: ?u32 = null;
    var directories: std.enums.EnumArray(emitter.Group, ?[]const u8) = .initFill(null);
    var ir_path: ?[]const u8 = null;
    var fingerprint_path: ?[]const u8 = null;
    var index: usize = 0;
    next: while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--target")) {
            index += 1;
            if (index == args.len) return error.MissingValue;
            target = ir.Target.parse(args[index]) orelse return error.InvalidTarget;
            continue;
        }
        if (std.mem.eql(u8, arg, "--cpp-shards")) {
            index += 1;
            if (index == args.len) return error.MissingValue;
            cpp_shards = try std.fmt.parseInt(u32, args[index], 10);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--ir=")) {
            ir_path = arg["--ir=".len..];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--fingerprint=")) {
            fingerprint_path = arg["--fingerprint=".len..];
            continue;
        }
        for (std.enums.values(emitter.Group)) |group| {
            const flag = switch (group) {
                inline else => |tag| "--" ++ @tagName(tag) ++ "=",
            };
            if (std.mem.startsWith(u8, arg, flag)) {
                directories.set(group, arg[flag.len..]);
                continue :next;
            }
        }
        return error.UnknownArgument;
    }
    const shards = cpp_shards orelse return error.MissingCppShards;
    if (shards == 0) return error.InvalidCppShards;
    var resolved: std.enums.EnumArray(emitter.Group, []const u8) = undefined;
    for (std.enums.values(emitter.Group)) |group| resolved.set(group, directories.get(group) orelse return error.MissingOutputDirectory);
    return .{
        .target = target orelse return error.MissingTarget,
        .cpp_shards = shards,
        .directories = resolved,
        .ir = ir_path orelse return error.MissingIr,
        .fingerprint = fingerprint_path orelse return error.MissingFingerprint,
    };
}

fn emit(init: std.process.Init, options: EmitOptions) !void {
    const arena = init.arena.allocator();
    const result = try normalize.normalize(arena, &modules, &source_stems, .{ .target = options.target });
    const normalized = switch (result) {
        .ir => |normalized| normalized,
        .diagnostics => |diagnostics| {
            var buffer: [4096]u8 = undefined;
            var stderr = Io.File.stderr().writer(init.io, &buffer);
            for (diagnostics) |diagnostic| {
                stderr.interface.print("error: {s}: {s}\n", .{ diagnostic.location, diagnostic.message }) catch {};
            }
            stderr.interface.flush() catch {};
            return error.SchemaRule;
        },
    };

    @setEvalBranchQuota(500_000);
    const fingerprint = normalize.fingerprint(normalized);

    var renderer: emitter.Emitter = .{
        .ir = &normalized,
        .arena = arena,
        .fingerprint = fingerprint,
        .cpp_shard_count = options.cpp_shards,
    };
    const files = try emitter.emitAll(&renderer);

    var directories: std.enums.EnumArray(emitter.Group, Io.Dir) = undefined;
    for (std.enums.values(emitter.Group)) |group| {
        directories.set(group, try Io.Dir.cwd().createDirPathOpen(init.io, options.directories.get(group), .{}));
    }
    defer for (std.enums.values(emitter.Group)) |group| directories.get(group).close(init.io);
    for (files) |file| try directories.get(file.group).writeFile(init.io, .{ .sub_path = file.name, .data = file.data });

    try Io.Dir.cwd().writeFile(init.io, .{ .sub_path = options.fingerprint, .data = try std.fmt.allocPrint(arena, "0x{x}\n", .{fingerprint}) });
    const document = try binding_document.create(arena, &normalized);
    var serialized: Io.Writer.Allocating = .init(arena);
    try std.zon.stringify.serialize(document, .{ .whitespace = false }, &serialized.writer);
    try Io.Dir.cwd().writeFile(init.io, .{ .sub_path = options.ir, .data = serialized.written() });
}
