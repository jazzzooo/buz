/// Returns true if the passed type will coerce to []const u8.
/// Any of the following are considered strings:
/// ```
/// []const u8, [:S]const u8, *const [N]u8, *const [N:S]u8,
/// []u8, [:S]u8, *[:S]u8, *[N:S]u8.
/// ```
/// These types are not considered strings:
/// ```
/// u8, [N]u8, [*]const u8, [*:0]const u8,
/// [*]const [N]u8, []const u16, []const i8,
/// *const u8, ?[]const u8, ?*const [N]u8.
/// ```
pub inline fn isByteSliceLike(comptime T: type) bool {
    const pointer = switch (@typeInfo(T)) {
        .pointer => |info| info,
        else => return false,
    };
    if (pointer.attrs.@"volatile" or pointer.attrs.@"allowzero") return false;
    return switch (pointer.size) {
        .slice => pointer.child == u8,
        .one => switch (@typeInfo(pointer.child)) {
            .array => |array| array.child == u8,
            else => false,
        },
        .many, .c => false,
    };
}

pub inline fn isNumber(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .float, .comptime_int, .comptime_float => true,
        else => false,
    };
}

pub inline fn isContainer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"opaque", .@"union" => true,
        else => false,
    };
}

pub fn isExternContainer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| s.layout == .@"extern",
        .@"union" => |u| u.layout == .@"extern",
        else => false,
    };
}
