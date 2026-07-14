Type: type,
symbol_name: []const u8,
local_name: []const u8,

Parent: type,

pub fn wrappedName(comptime this: *const @This()) []const u8 {
    return comptime "wrap" ++ this.symbol_name;
}
