//! Rope-like data structure for joining many small strings into one big string.
//! Implemented as a linked list of potentially-owned slices and a length.

const StringJoiner = @This();

/// Temporary allocator used for nodes and duplicated strings.
/// It is recommended to use a stack-fallback allocator for this.
allocator: Allocator,

/// Total length of all nodes
len: usize = 0,

head: ?*Node = null,
tail: ?*Node = null,

const Node = struct {
    allocator: NullableAllocator = .{},
    slice: []const u8 = "",
    next: ?*Node = null,

    pub fn init(joiner_alloc: Allocator, slice: []const u8, slice_alloc: ?Allocator) !*Node {
        const node = try joiner_alloc.create(Node);
        node.* = .{
            .slice = slice,
            .allocator = NullableAllocator.init(slice_alloc),
        };
        return node;
    }

    pub fn deinit(node: *Node, joiner_alloc: Allocator) void {
        node.allocator.free(node.slice);
        joiner_alloc.destroy(node);
    }
};

pub fn take(this: *StringJoiner) StringJoiner {
    const owned = this.*;
    this.* = .{ .allocator = owned.allocator };
    return owned;
}

/// `data` is expected to live until `.done` is called
pub fn pushStatic(this: *StringJoiner, data: []const u8) !void {
    try this.push(data, null);
}

/// `data` is cloned
pub fn pushCloned(this: *StringJoiner, data: []const u8) !void {
    if (data.len == 0) return;
    try this.push(
        try this.allocator.dupe(u8, data),
        this.allocator,
    );
}

/// When an allocator is supplied, consumes `data` on both success and failure.
pub fn push(this: *StringJoiner, data: []const u8, allocator: ?Allocator) !void {
    errdefer if (allocator) |owner| owner.free(data);
    if (data.len == 0) {
        if (allocator) |owner| owner.free(data);
        return;
    }
    const len = std.math.add(usize, this.len, data.len) catch return error.OutOfMemory;
    const new_tail = try Node.init(this.allocator, data, allocator);

    if (this.tail) |current_tail| {
        current_tail.next = new_tail;
    } else {
        assert(this.head == null);
        this.head = new_tail;
    }
    this.tail = new_tail;
    this.len = len;
}

/// This deinits the string joiner on success, the new string is owned by `allocator`
pub fn done(this: *StringJoiner, allocator: Allocator) ![]u8 {
    return try this.doneWithEnd(allocator, &.{});
}

pub fn deinit(this: *StringJoiner) void {
    const owned = this.take();
    var current: ?*Node = owned.head orelse {
        assert(owned.tail == null);
        assert(owned.len == 0);
        return;
    };

    while (current) |node| {
        const prev = node;
        current = node.next;
        prev.deinit(this.allocator);
    }
}

/// Same as `.done`, but appends extra slice `end`
pub fn doneWithEnd(this: *StringJoiner, allocator: Allocator, end: []const u8) ![]u8 {
    var current: ?*Node = this.head orelse {
        assert(this.tail == null);
        assert(this.len == 0);

        if (end.len > 0) {
            return allocator.dupe(u8, end);
        }

        return &.{};
    };

    const total_len = std.math.add(usize, this.len, end.len) catch return error.OutOfMemory;
    const slice = try allocator.alloc(u8, total_len);

    var remaining = slice;
    while (current) |node| {
        @memcpy(remaining[0..node.slice.len], node.slice);
        remaining = remaining[node.slice.len..];

        current = node.next;
    }

    bun.assert(remaining.len == end.len);
    @memcpy(remaining, end);
    // Borrowed nodes and the suffix may reference storage owned by another node.
    this.deinit();

    return slice;
}

pub fn lastByte(this: *const StringJoiner) u8 {
    const slice = (this.tail orelse return 0).slice;
    assert(slice.len > 0);
    return slice[slice.len - 1];
}

pub fn ensureNewlineAtEnd(this: *StringJoiner) !void {
    if (this.tail != null and this.lastByte() != '\n') {
        try this.pushStatic("\n");
    }
}

pub fn contains(this: *const StringJoiner, slice: []const u8) bool {
    var el = this.head;
    while (el) |node| {
        el = node.next;
        if (bun.strings.contains(node.slice, slice)) return true;
    }

    return false;
}

test "joining and transferring strings leave an empty reusable owner" {
    const allocator = std.testing.allocator;
    var joiner = StringJoiner{ .allocator = allocator };
    defer joiner.deinit();
    try joiner.pushCloned("first");
    try joiner.pushStatic(" second");

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, joiner.done(failing.allocator()));
    try std.testing.expectEqual(@as(usize, 12), joiner.len);
    const first = try joiner.done(allocator);
    defer allocator.free(first);
    try std.testing.expectEqualStrings("first second", first);
    try std.testing.expectEqual(@as(usize, 0), joiner.len);
    try std.testing.expect(joiner.head == null and joiner.tail == null);
    joiner.deinit();

    try joiner.pushCloned("third");
    var transferred = joiner.take();
    defer transferred.deinit();
    joiner.deinit();
    const third = try transferred.doneWithEnd(allocator, "!");
    defer allocator.free(third);
    try std.testing.expectEqualStrings("third!", third);
    try std.testing.expectEqual(@as(usize, 0), transferred.len);
    try std.testing.expect(transferred.head == null and transferred.tail == null);

    const shared = try allocator.dupe(u8, "shared");
    try joiner.push(shared, allocator);
    try joiner.pushStatic(shared[1..]);
    const aliased = try joiner.doneWithEnd(allocator, shared[0..2]);
    defer allocator.free(aliased);
    try std.testing.expectEqualStrings("sharedharedsh", aliased);
}

test "failed string appends release transferred storage without changing the joiner" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: Allocator) !void {
            var joiner = StringJoiner{ .allocator = allocator };
            defer joiner.deinit();
            try joiner.pushStatic("first");
            const len = joiner.len;
            const head = joiner.head;
            const tail = joiner.tail;
            const second = try allocator.dupe(u8, " second");
            joiner.push(second, allocator) catch |err| {
                try std.testing.expectEqual(len, joiner.len);
                try std.testing.expect(joiner.head == head and joiner.tail == tail);
                try std.testing.expect(tail.?.next == null);
                return err;
            };
            try joiner.pushCloned(" third");
            try joiner.ensureNewlineAtEnd();
            const joined = try joiner.done(allocator);
            defer allocator.free(joined);
            try std.testing.expectEqualStrings("first second third\n", joined);
        }
    }.run, .{});
}

const std = @import("std");
const Allocator = std.mem.Allocator;

const bun = @import("bun");
const NullableAllocator = bun.NullableAllocator;
const assert = bun.assert;
