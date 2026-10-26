pub fn Collection(comptime Types: type) type {
    const BunTest = Types.BunTest;
    const BunTestRoot = Types.BunTestRoot;
    const DescribeScope = Types.DescribeScope;
    const HandleUncaughtExceptionResult = Types.HandleUncaughtExceptionResult;
    const RefDataValue = Types.RefDataValue;
    const StoredTestCallback = Types.StoredTestCallback;

    return struct {
        locked: bool = false,
        describe_callback_queue: std.array_list.Managed(QueuedDescribe),
        current_scope_callback_queue: std.array_list.Managed(QueuedDescribe),
        root_scope: *DescribeScope,
        active_scope: *DescribeScope,
        filter_buffer: std.array_list.Managed(u8),

        const Self = @This();

        pub const QueuedDescribe = struct {
            callback: StoredTestCallback,
            active_scope: *DescribeScope,
            new_scope: *DescribeScope,

            pub fn deinit(this: *QueuedDescribe) void {
                this.callback.deinit();
            }

            pub fn take(this: *QueuedDescribe) QueuedDescribe {
                return .{
                    .callback = this.callback.take(),
                    .active_scope = this.active_scope,
                    .new_scope = this.new_scope,
                };
            }
        };

        pub fn init(gpa: std.mem.Allocator, bun_test_root: *BunTestRoot, only: bool) Self {
            group.begin(@src());
            defer group.end();

            const root_scope = DescribeScope.create(gpa, .{
                .parent = bun_test_root.hook_scope,
                .name = null,
                .concurrent = false,
                .mode = .normal,
                .only = if (only) .contains else .no,
                .has_callback = false,
                .test_id_for_debugger = 0,
                .line_no = 0,
            });

            return .{
                .describe_callback_queue = .init(gpa),
                .current_scope_callback_queue = .init(gpa),
                .root_scope = root_scope,
                .active_scope = root_scope,
                .filter_buffer = .init(gpa),
            };
        }

        pub fn deinit(this: *Self) void {
            const buntest: *BunTest = @fieldParentPtr("collection", this);
            this.root_scope.destroy(buntest.gpa);
            for (this.describe_callback_queue.items) |*item| item.deinit();
            this.describe_callback_queue.deinit();
            for (this.current_scope_callback_queue.items) |*item| item.deinit();
            this.current_scope_callback_queue.deinit();
            this.filter_buffer.deinit();
        }

        pub fn enqueueDescribeCallback(this: *Self, new_scope: *DescribeScope, callback: ?*StoredTestCallback) bun.JSError!void {
            group.begin(@src());
            defer group.end();

            bun.assert(!this.locked);
            if (callback) |value| {
                group.log("enqueueDescribeCallback / {s} / in scope: {s}", .{ new_scope.base.name orelse "(unnamed)", this.active_scope.base.name orelse "(unnamed)" });
                try this.current_scope_callback_queue.ensureUnusedCapacity(1);
                this.current_scope_callback_queue.appendAssumeCapacity(.{
                    .active_scope = this.active_scope,
                    .callback = value.take(),
                    .new_scope = new_scope,
                });
            }
        }

        pub fn completeStep(this: *Self, data: RefDataValue) void {
            const previous_scope = switch (data) {
                .collection => |collection| collection.active_scope,
                else => unreachable,
            };
            group.log("collection:runOneCompleted reset scope back from {s}", .{this.active_scope.base.name orelse "undefined"});
            this.active_scope = previous_scope;
            group.log("collection:runOneCompleted reset scope back to {s}", .{this.active_scope.base.name orelse "undefined"});
        }

        pub fn promoteCallbacks(this: *Self) void {
            var index = this.current_scope_callback_queue.items.len;
            while (index > 0) {
                index -= 1;
                const item = &this.current_scope_callback_queue.items[index];
                if (item.new_scope.failed) {
                    item.deinit();
                } else {
                    bun.handleOom(this.describe_callback_queue.append(item.take()));
                }
            }
            this.current_scope_callback_queue.clearRetainingCapacity();
        }

        pub fn handleUncaughtException(this: *Self, _: RefDataValue) HandleUncaughtExceptionResult {
            group.begin(@src());
            defer group.end();
            this.active_scope.failed = true;
            return .show_unhandled_error_in_describe;
        }
    };
}

const std = @import("std");
const bun = @import("bun");
const group = @import("./debug.zig").group;
