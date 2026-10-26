pub const State = struct {
    ref_count: RefCount = .init(),
    aborted: std.atomic.Value(bool) = .init(false),

    const RefCount = bun.ptr.ThreadSafeRefCount(State, "ref_count", destroy, .{});

    fn destroy(state: *State) void {
        bun.destroy(state);
    }
};

pub const Token = struct {
    state: ?bun.ptr.RefPtr(State) = null,
    initially_aborted: bool = false,

    pub fn initSnapshot(initial: bool) Token {
        return .{ .initially_aborted = initial };
    }

    pub fn initShared(state: bun.ptr.RefPtr(State)) Token {
        return .{ .state = state };
    }

    pub fn aborted(token: Token) bool {
        const state = token.state orelse return token.initially_aborted;
        return state.data.aborted.load(.acquire);
    }

    pub fn deinit(token: Token) void {
        if (token.state) |state| state.deref();
    }
};

const bun = @import("bun");
const std = @import("std");
