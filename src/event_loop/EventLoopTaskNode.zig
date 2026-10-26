const EventLoopTaskNode = @This();

next: ?*EventLoopTaskNode = null,
kind: enum { engine, native },
auto_delete: bool = false,

pub const Queue = bun.UnboundedQueue(EventLoopTaskNode, .next);

const bun = @import("bun");
