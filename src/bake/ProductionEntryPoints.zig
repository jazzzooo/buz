const EntryPointMap = @This();

root: []const u8,
allocator: std.mem.Allocator,
files: HashMap,

const HashMap = std.array_hash_map.Custom(InputFile, OutputFile.Index, InputFile.ArrayHashContext, true);

pub const InputFile = struct {
    abs_path_ptr: [*]const u8,
    abs_path_len: u32,
    side: BakeCore.Side,

    pub fn init(absolute_path: []const u8, side: BakeCore.Side) InputFile {
        return .{
            .abs_path_ptr = absolute_path.ptr,
            .abs_path_len = @intCast(absolute_path.len),
            .side = side,
        };
    }

    pub fn absPath(input: InputFile) []const u8 {
        return input.abs_path_ptr[0..input.abs_path_len];
    }

    const ArrayHashContext = struct {
        pub fn hash(_: @This(), input: InputFile) u32 {
            return bun.hash32(input.absPath()) +% @backingInt(input.side);
        }

        pub fn eql(_: @This(), left: InputFile, right: InputFile, _: usize) bool {
            return left.side == right.side and bun.strings.eql(left.absPath(), right.absPath());
        }
    };
};

pub fn getOrPutEntryPoint(map: *EntryPointMap, absolute_path: []const u8, side: BakeCore.Side) !FrameworkRouter.OpaqueFileId {
    const entry = try map.files.getOrPut(map.allocator, InputFile.init(absolute_path, side));
    if (!entry.found_existing) {
        errdefer map.files.swapRemoveAt(entry.index);
        entry.key_ptr.* = InputFile.init(try map.allocator.dupe(u8, absolute_path), side);
    }
    return FrameworkRouter.OpaqueFileId.init(@intCast(entry.index));
}

pub fn getFileIdForRouter(map: *EntryPointMap, absolute_path: []const u8, _: FrameworkRouter.Route.Index, _: FrameworkRouter.Route.FileKind) !FrameworkRouter.OpaqueFileId {
    return map.getOrPutEntryPoint(absolute_path, .server);
}

pub fn onRouterCollisionError(map: *EntryPointMap, relative_path: []const u8, other_id: FrameworkRouter.OpaqueFileId, kind: FrameworkRouter.Route.FileKind) bun.OOM!void {
    Output.errGeneric("Multiple {s} matching the same route pattern is ambiguous", .{
        switch (kind) {
            .page => "pages",
            .layout => "layout",
        },
    });
    Output.prettyErrorln("  - <blue>{s}<r>", .{relative_path});
    const other_path = try std.fs.path.relative(
        map.allocator,
        map.root,
        null,
        map.root,
        map.files.keys()[other_id.get()].absPath(),
    );
    defer map.allocator.free(other_path);
    Output.prettyErrorln("  - <blue>{s}<r>", .{other_path});
    Output.flush();
}

pub fn onRouterSyntaxError(_: *EntryPointMap, relative_path: []const u8, route_log: FrameworkRouter.TinyLog) bun.OOM!void {
    route_log.print(relative_path);
}

const std = @import("std");

const bun = @import("bun");
const Output = bun.Output;
const OutputFile = bun.options.OutputFile;

const BakeCore = @import("./BakeCore.zig");
const FrameworkRouter = @import("./FrameworkRouter.zig");
