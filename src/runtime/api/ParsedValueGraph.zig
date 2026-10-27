const bun = @import("bun");
const std = @import("std");

pub const Error = bun.OOM || error{ GraphTooLarge, UnsupportedExpression };

pub fn inputTooLargeMessage(length: usize) bun.OOM!bun.bindgen.DOMString {
    const message = try bun.String.createFormat(
        "The value of \"input.byteLength\" is out of range. It must be <= {d}. Received {d}",
        .{ std.math.maxInt(i32), length },
    );
    return bun.bindgen.DOMString.fromBunString(message);
}

pub fn fromExpr(
    comptime Graph: type,
    root: bun.ast.Expr,
    allocator: std.mem.Allocator,
) Error!Graph {
    var builder: Builder(Graph) = .{ .allocator = allocator };
    defer builder.deinit();

    const root_index = try builder.ensureNode(root);
    try builder.expandCollections();
    return builder.finish(root_index);
}

fn Builder(comptime Graph: type) type {
    const Nodes = @FieldType(Graph, "nodes");
    const Node = Nodes.Element;
    const Edges = @FieldType(Graph, "edges");
    const Edge = Edges.Element;
    const Collection = struct {
        index: u32,
        value: union(enum) {
            array: *bun.ast.E.Array,
            object: *bun.ast.E.Object,
        },
    };

    return struct {
        allocator: std.mem.Allocator,
        nodes: std.ArrayList(Node) = .empty,
        edges: std.ArrayList(Edge) = .empty,
        node_edges: std.ArrayList(std.ArrayList(Edge)) = .empty,
        collections: std.ArrayList(Collection) = .empty,
        seen: std.AutoHashMapUnmanaged(*const anyopaque, u32) = .empty,
        nodes_transferred: bool = false,

        const Self = @This();

        fn deinit(self: *Self) void {
            if (!self.nodes_transferred) {
                for (self.nodes.items) |*node| node.text.deinit();
            }
            self.nodes.deinit(self.allocator);
            self.edges.deinit(self.allocator);
            for (self.node_edges.items) |*edges| edges.deinit(self.allocator);
            self.node_edges.deinit(self.allocator);
            self.collections.deinit(self.allocator);
            self.seen.deinit(self.allocator);
        }

        fn finish(self: *Self, root: u32) Error!Graph {
            for (self.node_edges.items, 0..) |node_edges, index| {
                self.nodes.items[index].edge_start = std.math.cast(u32, self.edges.items.len) orelse return error.GraphTooLarge;
                self.nodes.items[index].edge_count = std.math.cast(u32, node_edges.items.len) orelse return error.GraphTooLarge;
                try self.edges.appendSlice(self.allocator, node_edges.items);
            }

            var nodes = try Nodes.fromOwnedSlice(self.nodes.items);
            self.nodes_transferred = true;
            errdefer nodes.deinit();

            var edges = try Edges.fromOwnedSlice(self.edges.items);
            errdefer edges.deinit();

            return .{ .nodes = nodes, .edges = edges, .root = root };
        }

        fn ensureNode(self: *Self, expr: bun.ast.Expr) Error!u32 {
            return switch (expr.data) {
                .e_null => self.appendPrimitive(.nulled, 0, false, bun.bindgen.DOMString.empty()),
                .e_undefined, .e_missing => self.appendPrimitive(.undefined, 0, false, bun.bindgen.DOMString.empty()),
                .e_boolean => |value| self.appendPrimitive(.boolean, 0, value.value, bun.bindgen.DOMString.empty()),
                .e_number => |value| self.appendPrimitive(.number, value.value, false, bun.bindgen.DOMString.empty()),
                .e_string => |value| self.appendString(value),
                .e_array => |value| self.appendCollection(value, .{ .array = value }),
                .e_object => |value| self.appendCollection(value, .{ .object = value }),
                else => error.UnsupportedExpression,
            };
        }

        fn expandCollections(self: *Self) Error!void {
            while (self.collections.pop()) |collection| {
                switch (collection.value) {
                    .array => |array| for (array.slice()) |item| {
                        const target = try self.ensureNode(item);
                        try self.node_edges.items[collection.index].append(self.allocator, .{
                            .key = 0,
                            .target = target,
                        });
                    },
                    .object => |object| for (object.properties.slice()) |property| {
                        const key = property.key orelse return error.UnsupportedExpression;
                        const target = property.value orelse return error.UnsupportedExpression;
                        const key_index = try self.ensureNode(key);
                        const target_index = try self.ensureNode(target);
                        try self.node_edges.items[collection.index].append(self.allocator, .{
                            .key = key_index,
                            .target = target_index,
                        });
                    },
                }
            }
        }

        fn appendPrimitive(
            self: *Self,
            kind: @FieldType(Node, "kind"),
            number: f64,
            boolean: bool,
            text: bun.bindgen.DOMString,
        ) Error!u32 {
            const index = try self.nextIndex();
            try self.nodes.ensureUnusedCapacity(self.allocator, 1);
            try self.node_edges.ensureUnusedCapacity(self.allocator, 1);
            self.nodes.appendAssumeCapacity(.{
                .kind = kind,
                .number = number,
                .boolean = boolean,
                .text = text,
                .edge_start = 0,
                .edge_count = 0,
            });
            self.node_edges.appendAssumeCapacity(.empty);
            return index;
        }

        fn appendString(self: *Self, value: *bun.ast.E.String) Error!u32 {
            value.resolveRopeIfNeeded(self.allocator);
            var text = if (value.isUTF8())
                try bun.bindgen.DOMString.fromUTF8(value.slice8())
            else
                try bun.bindgen.DOMString.fromUTF16(value.slice16());
            errdefer text.deinit();
            return self.appendPrimitive(.string, 0, false, text);
        }

        fn appendCollection(self: *Self, identity_value: anytype, value: @FieldType(Collection, "value")) Error!u32 {
            const identity: *const anyopaque = @ptrCast(identity_value);
            if (self.seen.get(identity)) |index| return index;

            const index = try self.appendPrimitive(
                switch (value) {
                    .array => .array,
                    .object => .object,
                },
                0,
                false,
                bun.bindgen.DOMString.empty(),
            );
            try self.seen.put(self.allocator, identity, index);
            try self.collections.append(self.allocator, .{ .index = index, .value = value });
            return index;
        }

        fn nextIndex(self: *const Self) Error!u32 {
            return std.math.cast(u32, self.nodes.items.len) orelse error.GraphTooLarge;
        }
    };
}
