pub fn ObjectPool(
    comptime Type: type,
    comptime Init: ?fn (allocator: std.mem.Allocator) anyerror!Type,
    comptime thread_local: bool,
    comptime max_count: comptime_int,
) type {
    return struct {
        const Pool = @This();
        const LinkedList = std.SinglyLinkedList;

        pub const Node = struct {
            link: LinkedList.Node = .{},
            allocator: std.mem.Allocator,
            data: Type,

            pub inline fn release(node: *Node) void {
                Pool.release(node);
            }
        };

        const MaxCountInt = std.math.IntFittingRange(0, max_count);
        const State = struct {
            list: LinkedList = .{},
            count: MaxCountInt = 0,
        };
        const Storage = if (thread_local)
            struct {
                threadlocal var value: State = .{};
            }
        else
            struct {
                var value: State = .{};
            };

        inline fn state() *State {
            return &Storage.value;
        }

        inline fn fromLink(link: *LinkedList.Node) *Node {
            return @fieldParentPtr("link", link);
        }

        fn pop() ?*Node {
            const pool_state = state();
            const node = fromLink(pool_state.list.popFirst() orelse return null);
            if (comptime std.meta.hasMethod(Type, "reset")) node.data.reset();
            if (comptime max_count > 0) pool_state.count -= 1;
            return node;
        }

        pub fn full() bool {
            if (comptime max_count == 0) return false;
            return state().count >= max_count;
        }

        pub fn getIfExists() ?*Node {
            return pop();
        }

        pub fn get(allocator: std.mem.Allocator) *Node {
            if (pop()) |node| return node;

            const new_node = bun.handleOom(allocator.create(Node));
            new_node.* = .{
                .allocator = allocator,
                .data = if (comptime Init) |init|
                    init(allocator) catch unreachable
                else
                    undefined,
            };
            return new_node;
        }

        pub fn push(allocator: std.mem.Allocator, pooled: Type) void {
            if (comptime bun.Environment.allow_assert) bun.assert(!full());

            const node = bun.handleOom(allocator.create(Node));
            node.* = .{
                .allocator = allocator,
                .data = pooled,
            };
            release(node);
        }

        pub fn release(node: *Node) void {
            const pool_state = state();
            if (comptime max_count > 0) {
                if (pool_state.count >= max_count) {
                    destroyNode(node);
                    return;
                }
                pool_state.count += 1;
            }

            pool_state.list.prepend(&node.link);
        }

        pub fn deleteAll() void {
            const pool_state = state();
            pool_state.count = 0;
            while (pool_state.list.popFirst()) |link| {
                destroyNode(fromLink(link));
            }
        }

        fn destroyNode(node: *Node) void {
            // TODO: Once a generic-allocator version of `BabyList` is added, change
            // `ByteListPool` in `bun.js/webcore.zig` to use a managed default-allocator
            // `ByteList` instead, and then get rid of the special-casing for `ByteList`
            // here. This will fix a memory leak.
            if (comptime Type != bun.ByteList) {
                bun.memory.deinit(&node.data);
            }
            node.allocator.destroy(node);
        }
    };
}

const bun = @import("bun");
const std = @import("std");
