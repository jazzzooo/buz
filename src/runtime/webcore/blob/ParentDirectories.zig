const ParentDirectories = @This();

target: usize,
current: usize,

pub fn init(path: []const u8) ?ParentDirectories {
    const parent = std.fs.path.dirnameWindows(path) orelse return null;
    return .{ .target = parent.len, .current = parent.len };
}

pub fn advance(this: *ParentDirectories, path: []const u8, failure: ?bun.sys.E) enum { more, done, failed } {
    if (failure) |err| {
        if (err == .NOENT) {
            if (std.fs.path.dirnameWindows(path[0..this.current])) |parent| {
                if (parent.len < this.current) {
                    this.current = parent.len;
                    return .more;
                }
            }
        }
        if (err != .EXIST) return .failed;
    }
    if (this.current == this.target) return .done;
    var next = this.current;
    while (next < this.target and isSeparator(path[next])) : (next += 1) {}
    while (next < this.target and !isSeparator(path[next])) : (next += 1) {}
    bun.assert(next > this.current);
    this.current = next;
    return .more;
}

fn isSeparator(byte: u8) bool {
    return byte == '/' or byte == '\\';
}

const std = @import("std");
const bun = @import("bun");
