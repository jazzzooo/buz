const Param = @This();

name: []const u8,
value: []const u8,

pub const List = @import("std").MultiArrayList(Param);
