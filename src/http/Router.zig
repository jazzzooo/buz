const std = @import("std");

const Self = @This();

pub const Priority = enum(u2) { upgrade, normal, fallback };

const Node = struct {
    segment: []const u8,
    upgrade: bool,
    child: ?usize = null,
    sibling: ?usize = null,
    handlers: [3]?usize = .{ null, null, null },
};

const Method = struct { name: []const u8, root: usize };

arena: std.heap.ArenaAllocator,
nodes: std.ArrayList(Node) = .empty,
methods: std.ArrayList(Method) = .empty,
max_depth: usize = 0,

pub fn init(allocator: std.mem.Allocator) Self {
    return .{ .arena = .init(allocator) };
}

pub fn deinit(self: *Self) void {
    self.arena.deinit();
    self.* = undefined;
}

pub fn memoryCost(self: *const Self) usize {
    return self.arena.queryCapacity();
}

fn rootFor(self: *const Self, method: []const u8) ?usize {
    for (self.methods.items) |entry| {
        if (std.mem.eql(u8, method, entry.name)) return entry.root;
    }
    return null;
}

fn rank(node: Node) u3 {
    const kind: u3 = if (node.segment.len == 0) 0 else switch (node.segment[0]) {
        ':' => 1,
        '*' => 2,
        else => 0,
    };
    return kind + @as(u3, if (node.upgrade) 0 else 3);
}

fn childFor(self: *Self, parent: usize, segment: []const u8, upgrade: bool) std.mem.Allocator.Error!usize {
    const name = if (std.mem.startsWith(u8, segment, ":")) ":" else segment;
    const candidate: Node = .{ .segment = name, .upgrade = upgrade };
    var previous: ?usize = null;
    var cursor = self.nodes.items[parent].child;
    while (cursor) |index| {
        const child = self.nodes.items[index];
        if (child.upgrade == upgrade and std.mem.eql(u8, child.segment, name)) return index;
        if (rank(child) > rank(candidate)) break;
        previous = index;
        cursor = child.sibling;
    }
    const allocator = self.arena.allocator();
    const index = self.nodes.items.len;
    try self.nodes.append(allocator, .{
        .segment = try allocator.dupe(u8, name),
        .upgrade = upgrade,
        .sibling = cursor,
    });
    if (previous) |before| {
        self.nodes.items[before].sibling = index;
    } else {
        self.nodes.items[parent].child = index;
    }
    return index;
}

/// A builder that encounters an allocation failure must be discarded.
pub fn add(self: *Self, method: []const u8, pattern: []const u8, priority: Priority, handler: usize) std.mem.Allocator.Error!void {
    const allocator = self.arena.allocator();
    var node = self.rootFor(method) orelse root: {
        const index = self.nodes.items.len;
        try self.nodes.append(allocator, .{ .segment = "", .upgrade = false });
        try self.methods.append(allocator, .{ .name = try allocator.dupe(u8, method), .root = index });
        break :root index;
    };
    var remaining = pattern;
    var depth: usize = 1;
    while (splitSegment(&remaining)) |segment| {
        node = try self.childFor(node, segment, priority == .upgrade);
        depth += 1;
    }
    self.nodes.items[node].handlers[@backingInt(priority)] = handler;
    self.max_depth = @max(self.max_depth, depth);
}

fn splitSegment(path: *[]const u8) ?[]const u8 {
    if (path.len == 0) return null;
    const rest = path.*[1..];
    const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    path.* = rest[end..];
    return rest[0..end];
}

pub const Iterator = struct {
    const Frame = struct {
        remaining: []const u8,
        node: usize,
        child: ?usize,
        parameter_count: usize,
        handler: u2 = 0,
        terminal: bool,
    };

    router: *const Self,
    frames: []Frame,
    parameters: [][]const u8,
    depth: usize = 0,
    fallback: ?usize,
    path: []const u8,
    allocator: std.mem.Allocator,

    pub const Match = struct { handler: usize, parameters: []const []const u8 };

    pub fn init(router: *const Self, allocator: std.mem.Allocator, method: []const u8, path: []const u8) std.mem.Allocator.Error!Iterator {
        const frames = try allocator.alloc(Frame, router.max_depth);
        errdefer allocator.free(frames);
        var result: Iterator = .{
            .router = router,
            .frames = frames,
            .parameters = try allocator.alloc([]const u8, router.max_depth),
            .fallback = router.rootFor("*"),
            .path = path,
            .allocator = allocator,
        };
        if (router.rootFor(method)) |root| result.push(root, path, 0, path.len == 0);
        return result;
    }

    pub fn deinit(self: *Iterator) void {
        self.allocator.free(self.parameters);
        self.allocator.free(self.frames);
    }

    fn push(self: *Iterator, node: usize, remaining: []const u8, parameter_count: usize, terminal: bool) void {
        self.frames[self.depth] = .{
            .node = node,
            .remaining = remaining,
            .child = self.router.nodes.items[node].child,
            .parameter_count = parameter_count,
            .terminal = terminal,
        };
        self.depth += 1;
    }

    pub fn next(self: *Iterator) ?Match {
        while (true) {
            if (self.depth == 0) {
                const fallback = self.fallback orelse return null;
                self.fallback = null;
                self.push(fallback, self.path, 0, self.path.len == 0);
            }
            const frame = &self.frames[self.depth - 1];
            if (frame.terminal) {
                const node = &self.router.nodes.items[frame.node];
                while (frame.handler < 3) {
                    const index = frame.handler;
                    frame.handler += 1;
                    if (node.handlers[index]) |handler| return .{
                        .handler = handler,
                        .parameters = self.parameters[0..frame.parameter_count],
                    };
                }
                self.depth -= 1;
                continue;
            }
            const child_index = frame.child orelse {
                self.depth -= 1;
                continue;
            };
            const child = self.router.nodes.items[child_index];
            frame.child = child.sibling;
            var remaining = frame.remaining;
            const segment = splitSegment(&remaining).?;
            if (std.mem.startsWith(u8, child.segment, "*")) {
                self.push(child_index, "", frame.parameter_count, true);
            } else if (std.mem.eql(u8, child.segment, ":")) {
                if (segment.len == 0) continue;
                self.parameters[frame.parameter_count] = segment;
                self.push(child_index, remaining, frame.parameter_count + 1, remaining.len == 0);
            } else if (std.mem.eql(u8, child.segment, segment)) {
                self.push(child_index, remaining, frame.parameter_count, remaining.len == 0);
            }
        }
    }
};
