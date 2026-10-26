pub const MySQLRequestQueue = @This();

requests: std.DoublyLinkedList = .{},
advancing: bool = false,

pipelined_requests: u32 = 0,
nonpipelinable_requests: u32 = 0,
// TODO: refactor to ENUM
waiting_to_prepare: bool = false,
is_ready_for_query: bool = true,

pub inline fn canExecuteQuery(this: *const @This(), connection: *const MySQLConnection) bool {
    return connection.isAbleToWrite() and
        this.is_ready_for_query and
        this.nonpipelinable_requests == 0 and
        this.pipelined_requests == 0;
}
pub inline fn canPrepareQuery(this: *const @This(), connection: *const MySQLConnection) bool {
    return connection.isAbleToWrite() and
        this.is_ready_for_query and
        !this.waiting_to_prepare and
        this.pipelined_requests == 0;
}

pub inline fn markAsReadyForQuery(this: *@This()) void {
    this.is_ready_for_query = true;
}
pub inline fn markAsPrepared(this: *@This()) void {
    this.waiting_to_prepare = false;
    if (this.current()) |request| {
        debug("markAsPrepared markAsPrepared", .{});
        request.markAsPrepared();
    }
}
pub inline fn canPipeline(this: *@This(), connection: *MySQLConnection) bool {
    if (bun.feature_flag.BUN_FEATURE_FLAG_DISABLE_SQL_AUTO_PIPELINING.get()) {
        @branchHint(.unlikely);
        return false;
    }

    return this.is_ready_for_query and
        this.nonpipelinable_requests == 0 and // need to wait for non pipelinable requests to finish
        !this.waiting_to_prepare and
        connection.isAbleToWrite();
}

pub fn markCurrentRequestAsFinished(this: *@This(), item: *JSMySQLQuery) void {
    this.waiting_to_prepare = false;
    if (item.isBeingPrepared()) {
        debug("markCurrentRequestAsFinished markAsPrepared", .{});
        item.markAsPrepared();
    } else if (item.isRunning()) {
        if (item.isPipelined()) {
            this.pipelined_requests -= 1;
        } else {
            this.nonpipelinable_requests -= 1;
        }
    }
}

pub fn advance(this: *@This(), connection: *MySQLConnection) void {
    if (this.advancing) return;
    this.advancing = true;
    defer {
        this.advancing = false;
        while (this.current()) |request| {
            if (!request.isCompleted()) break;
            this.remove(request);
        }
    }

    var cursor = this.requests.first;
    while (cursor) |node| {
        if (!connection.isAbleToWrite()) return;
        const request: *JSMySQLQuery = @fieldParentPtr("queue_node", node);

        if (request.isCompleted()) {
            cursor = node.next;
            this.remove(request);
            continue;
        }

        if (request.isBeingPrepared()) {
            debug("isBeingPrepared", .{});
            this.waiting_to_prepare = true;
            // cannot continue the queue until the current request is marked as prepared
            return;
        }
        if (request.isRunning()) {
            cursor = node.next;
            continue;
        }

        // Running or rejecting can invoke callbacks that drain the queue.
        request.ref();
        defer request.deref();
        const run_failed = run: {
            const outcome = request.run(connection) catch |err| {
                connection.onError(request, err);
                break :run true;
            };
            break :run switch (outcome) {
                .started => false,
                .cached_statement_failed => failed: {
                    connection.onErrorPacket(request, request.getStatement().?.error_response);
                    break :failed true;
                },
                .failed => |failure| failed: {
                    request.rejectWithMessage(failure.message, failure.err);
                    break :failed true;
                },
            };
        };
        if (!request.queued) return;
        if (run_failed) {
            cursor = node.next;
            this.remove(request);
            continue;
        }
        if (request.isBeingPrepared()) {
            debug("isBeingPrepared", .{});
            connection.resetConnectionTimeout();
            this.is_ready_for_query = false;
            this.waiting_to_prepare = true;
            return;
        } else if (request.isRunning()) {
            connection.resetConnectionTimeout();
            debug("isRunning after run", .{});
            this.is_ready_for_query = false;

            if (request.isPipelined()) {
                this.pipelined_requests += 1;
                if (this.canPipeline(connection)) {
                    debug("pipelined requests", .{});
                    cursor = node.next;
                    continue;
                }
                return;
            }
            debug("nonpipelinable requests", .{});
            this.nonpipelinable_requests += 1;
        }
        return;
    }
}

pub fn init() @This() {
    return .{};
}

pub fn isEmpty(this: *@This()) bool {
    return this.requests.first == null;
}

pub fn add(this: *@This(), request: *JSMySQLQuery) void {
    bun.assert(!request.queued);
    debug("add", .{});
    if (request.isBeingPrepared()) {
        this.is_ready_for_query = false;
        this.waiting_to_prepare = true;
    } else if (request.isRunning()) {
        this.is_ready_for_query = false;

        if (request.isPipelined()) {
            this.pipelined_requests += 1;
        } else {
            this.nonpipelinable_requests += 1;
        }
    }
    request.ref();
    request.queued = true;
    this.requests.append(&request.queue_node);
}

pub inline fn current(this: *const @This()) ?*JSMySQLQuery {
    return @fieldParentPtr("queue_node", this.requests.first orelse return null);
}

fn remove(this: *@This(), request: *JSMySQLQuery) void {
    bun.assert(request.queued);
    this.requests.remove(&request.queue_node);
    request.queue_node = .{};
    request.queued = false;
    request.deref();
}

pub fn clean(this: *@This(), reason: ?*const bun.bindgen.Root) void {
    this.cleanWithReason(if (reason) |value| .{ .original = value } else .none);
}

pub fn cleanWithPayload(this: *@This(), message: []const u8, options: ErrorPacket.MySQLErrorOptions) void {
    this.cleanWithReason(.{ .payload = .{ .message = message, .options = options } });
}

const CleanReason = union(enum) {
    none,
    original: *const bun.bindgen.Root,
    payload: struct {
        message: []const u8,
        options: ErrorPacket.MySQLErrorOptions,
    },
};

fn cleanWithReason(this: *@This(), reason: CleanReason) void {
    // Rejection callbacks can synchronously call .close()
    // (or otherwise fail the connection) and re-enter clean(). Swap the queue
    // into a local first so the re-entrant call sees an empty queue instead of
    // releasing the same requests twice.
    var requests = this.requests;
    this.requests = .{};
    this.pipelined_requests = 0;
    this.nonpipelinable_requests = 0;
    this.waiting_to_prepare = false;
    while (requests.popFirst()) |node| {
        const request: *JSMySQLQuery = @fieldParentPtr("queue_node", node);
        request.queue_node = .{};
        request.queued = false;
        defer request.deref();
        if (request.isCompleted()) {
            continue;
        }
        switch (reason) {
            .none => request.reject(error.ConnectionClosed),
            .original => |value| request.rejectWithRoot(value),
            .payload => |payload| request.rejectWithPayload(payload.message, payload.options),
        }
    }
}

pub fn deinit(this: *@This()) void {
    while (this.requests.popFirst()) |node| {
        const request: *JSMySQLQuery = @fieldParentPtr("queue_node", node);
        request.queue_node = .{};
        request.queued = false;
        // We cannot touch JS here
        request.markAsFailed();
        request.deref();
    }
    this.pipelined_requests = 0;
    this.nonpipelinable_requests = 0;
    this.waiting_to_prepare = false;
}

const std = @import("std");

const debug = bun.Output.scoped(.MySQLRequestQueue, .visible);

const JSMySQLQuery = @import("./MySQLQueryEngine.zig");
const MySQLConnection = @import("./MySQLConnectionEngine.zig");
const bun = @import("bun");
const ErrorPacket = @import("../../sql/mysql/protocol/ErrorPacket.zig");
