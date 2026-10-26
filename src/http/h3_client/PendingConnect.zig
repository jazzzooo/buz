//! DNS-pending QUIC connect. Created when `quic.Context.connect` returns
//! `.pending` (cache miss); the global DNS cache notifies via
//! `onDNSResolved[Threadsafe]`, at which point the resolved address is
//! handed to lsquic and the resulting `quic.Socket` bound to the waiting
//! `ClientSession`.
//!
//! Lifetime: holds one ref on `session` from `register` until
//! `onDNSResolved` runs. The `quic.PendingConnect` C handle is consumed by
//! exactly one of `resolved()` or `cancel()`.

const PendingConnect = @This();

session: *ClientSession,
pc: *quic.PendingConnect,
loop_ptr: *uws.Loop,
io: std.Io,
next: ?*PendingConnect = null,

pub fn register(session: *ClientSession, pc: *quic.PendingConnect, l: *uws.Loop) bun.OOM!void {
    const self = try bun.default_allocator.create(PendingConnect);
    errdefer bun.default_allocator.destroy(self);
    self.* = .{
        .session = session,
        .pc = pc,
        .loop_ptr = l,
        .io = l.internal_loop_data.getParent().io(),
    };
    session.ref();
    errdefer session.deref();
    try bun.dns.internal.registerQuic(
        pc.addrinfo(),
        .init(self),
    );
}

pub fn loop(this: *PendingConnect) *uws.Loop {
    return this.loop_ptr;
}

pub fn onDNSResolved(this: *PendingConnect) void {
    const session = this.session;
    defer {
        session.deref();
        bun.destroy(this);
    }
    if (session.closed or session.pending.items.len == 0) {
        // Every waiter was aborted while DNS was in flight; don't open a
        // connection nobody will use.
        this.pc.cancel();
        if (!session.closed) failSession(session, error.Aborted);
        return;
    }
    const qs = switch (this.pc.resolved()) {
        .socket => |socket| socket,
        .out_of_memory => {
            failSession(session, error.OutOfMemory);
            return;
        },
        .failed => {
            failSession(session, error.DNSResolutionFailed);
            return;
        },
    };
    session.qsocket = qs;
    qs.ext(ClientSession).* = session;
}

/// The worker queues completion without touching the HTTP-thread session.
/// `HTTPThread.drainEvents` delivers it on the next loop iteration.
pub fn onDNSResolvedThreadsafe(this: *PendingConnect) void {
    resolved_mutex.lockUncancelable(this.io);
    this.next = resolved_head;
    resolved_head = this;
    resolved_mutex.unlock(this.io);
    this.loop_ptr.wakeup();
}

pub fn drainResolved(io: std.Io) void {
    resolved_mutex.lockUncancelable(io);
    var head = resolved_head;
    resolved_head = null;
    resolved_mutex.unlock(io);
    while (head) |pc| {
        const next = pc.next;
        pc.onDNSResolved();
        head = next;
    }
}

pub fn failSession(session: *ClientSession, err: anyerror) void {
    session.closed = true;
    if (H3.ClientContext.get()) |ctx| ctx.unregister(session);
    while (session.pending.items.len > 0) {
        const stream = session.pending.items[0];
        const cl = stream.client;
        session.detach(stream);
        if (cl) |cl_| cl_.failFromH2(err);
    }
    _ = H3.live_sessions.fetchSub(1, .monotonic);
    session.deref();
}

var resolved_mutex: std.Io.Mutex = .init;
var resolved_head: ?*PendingConnect = null;

const std = @import("std");
const bun = @import("bun");

const H3 = bun.http.H3;
const ClientSession = H3.ClientSession;

const uws = bun.uws;
const quic = uws.quic;
