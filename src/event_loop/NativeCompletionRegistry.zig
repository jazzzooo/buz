const NativeCompletionRegistry = @This();

pub const Context = bun.bindgen.NativeCallbackContext(.vm);

pub const Entry = struct {
    context: Context,
    deliver: *const fn (Context) void,
    detach: *const fn (Context) void,
    /// Requests producer cancellation without waiting; detach may then join it.
    cancel: ?*const fn (Context) void = null,
    delivery: enum { once, repeating } = .once,
    previous: ?*Entry = null,
    next: ?*Entry = null,
    ready_next: ?*Entry = null,
    registered: bool = false,
    ready: bool = false,
    cancel_notified: bool = false,
};

pub const Scheduler = struct {
    context: Context,
    schedule: *const fn (Context) void,
    cancel: *const fn (Context) bool,
    destroy: *const fn (Context) void,
};

lock: std.atomic.Mutex = .unlocked,
references: std.atomic.Value(usize) = .init(1),
state: State = .open,
scheduler: Scheduler,
registry_previous: ?*NativeCompletionRegistry = null,
registry_next: ?*NativeCompletionRegistry = null,
entries: ?*Entry = null,
ready_head: ?*Entry = null,
ready_tail: ?*Entry = null,
task_scheduled: bool = false,

const State = enum {
    open,
    resetting,
    closed,
};

pub fn create(scheduler: Scheduler) bun.OOM!*NativeCompletionRegistry {
    const registry = try bun.default_allocator.create(NativeCompletionRegistry);
    registry.* = .{ .scheduler = scheduler };
    return registry;
}

pub fn retain(registry: *NativeCompletionRegistry) void {
    const references = registry.references.fetchAdd(1, .monotonic);
    if (references == 0) @panic("native completion registry retained after destruction");
}

pub fn release(registry: *NativeCompletionRegistry) void {
    const references = registry.references.fetchSub(1, .acq_rel);
    if (references == 0) @panic("native completion registry reference count underflowed");
    if (references == 1) {
        const scheduler = registry.scheduler;
        bun.default_allocator.destroy(registry);
        scheduler.destroy(scheduler.context);
    }
}

pub fn register(registry: *NativeCompletionRegistry, entry: *Entry) bool {
    registry.lockRegistry();
    defer registry.lock.unlock();

    if (registry.state != .open) return false;
    if (entry.registered or entry.ready) @panic("native completion endpoint registered twice");
    entry.next = registry.entries;
    if (registry.entries) |head| head.previous = entry;
    registry.entries = entry;
    entry.registered = true;
    entry.cancel_notified = false;
    return true;
}

pub fn submit(registry: *NativeCompletionRegistry, entry: *Entry) bool {
    if (entry.delivery != .once) @panic("repeating native delivery requires notify");
    return registry.enqueue(entry, false);
}

pub fn notify(registry: *NativeCompletionRegistry, entry: *Entry) bool {
    if (entry.delivery != .repeating) @panic("one-shot native delivery requires submit");
    return registry.enqueue(entry, true);
}

/// Delivers one ready endpoint on the registry's delivery thread.
pub fn deliverReady(registry: *NativeCompletionRegistry, entry: *Entry) bool {
    registry.retain();
    defer registry.release();
    registry.lockRegistry();
    if (registry.state != .open or !entry.registered or !entry.ready) {
        registry.lock.unlock();
        return false;
    }
    if (entry.delivery != .once) @panic("immediate native completion delivery requires a one-shot endpoint");
    registry.removeEntry(entry);
    registry.removeReady(entry);
    if (registry.ready_head == null) registry.cancelScheduled();
    registry.lock.unlock();
    entry.deliver(entry.context);
    return true;
}

fn enqueue(registry: *NativeCompletionRegistry, entry: *Entry, coalesce: bool) bool {
    registry.lockRegistry();
    defer registry.lock.unlock();

    if (registry.state != .open or !entry.registered) return false;
    if (entry.ready) {
        if (coalesce) return true;
        @panic("native completion endpoint submitted twice");
    }

    entry.ready = true;
    if (registry.ready_tail) |tail| {
        tail.ready_next = entry;
    } else {
        registry.ready_head = entry;
    }
    registry.ready_tail = entry;

    registry.scheduleDelivery();
    return true;
}

fn scheduleDelivery(registry: *NativeCompletionRegistry) void {
    if (!registry.task_scheduled and registry.ready_head != null) {
        registry.task_scheduled = true;
        registry.retain();
        registry.scheduler.schedule(registry.scheduler.context);
    }
}

pub fn detach(registry: *NativeCompletionRegistry, entry: *Entry) void {
    registry.retain();
    defer registry.release();
    registry.lockRegistry();
    if (!entry.registered) {
        registry.lock.unlock();
        return;
    }
    registry.removeEntry(entry);
    if (entry.ready) {
        registry.removeReady(entry);
        if (registry.ready_head == null) registry.cancelScheduled();
    }
    registry.lock.unlock();
    entry.detach(entry.context);
}

pub fn close(registry: *NativeCompletionRegistry) void {
    registry.retain();
    defer registry.release();
    registry.beginClose();
    registry.detachEntries();
}

pub fn beginClose(registry: *NativeCompletionRegistry) void {
    registry.retain();
    defer registry.release();
    registry.lockRegistry();
    registry.state = .closed;
    registry.cancelScheduled();
    registry.ready_head = null;
    registry.ready_tail = null;
    registry.lock.unlock();

    registry.cancelEntries();
}

pub fn reset(registry: *NativeCompletionRegistry) void {
    registry.retain();
    defer registry.release();
    registry.beginReset();
    registry.finishReset();
}

pub fn beginReset(registry: *NativeCompletionRegistry) void {
    registry.retain();
    defer registry.release();
    registry.lockRegistry();
    if (registry.state != .open) {
        registry.lock.unlock();
        return;
    }
    registry.state = .resetting;
    registry.cancelScheduled();
    registry.ready_head = null;
    registry.ready_tail = null;
    registry.lock.unlock();

    registry.cancelEntries();
}

pub fn finishReset(registry: *NativeCompletionRegistry) void {
    registry.retain();
    defer registry.release();
    registry.lockRegistry();
    const resetting = registry.state == .resetting;
    registry.lock.unlock();
    if (!resetting) return;
    registry.detachEntries();
    registry.lockRegistry();
    if (registry.state == .resetting) registry.state = .open;
    registry.lock.unlock();
}

pub fn isClosed(registry: *NativeCompletionRegistry) bool {
    registry.lockRegistry();
    defer registry.lock.unlock();
    return registry.state == .closed;
}

fn cancelScheduled(registry: *NativeCompletionRegistry) void {
    if (!registry.task_scheduled) return;
    if (registry.scheduler.cancel(registry.scheduler.context)) {
        registry.task_scheduled = false;
        registry.release();
    }
}

fn detachEntries(registry: *NativeCompletionRegistry) void {
    while (true) {
        registry.lockRegistry();
        const entry = registry.entries orelse {
            registry.lock.unlock();
            return;
        };
        registry.removeEntry(entry);
        entry.ready_next = null;
        entry.ready = false;
        registry.lock.unlock();

        // Reentrant shutdown must still see and detach the remaining endpoints.
        entry.detach(entry.context);
    }
}

fn cancelEntries(registry: *NativeCompletionRegistry) void {
    while (true) {
        registry.lockRegistry();
        var current = registry.entries;
        while (current) |entry| {
            if (entry.cancel != null and !entry.cancel_notified) break;
            current = entry.next;
        }
        const entry = current orelse {
            registry.lock.unlock();
            return;
        };
        entry.cancel_notified = true;
        const cancel = entry.cancel.?;
        const context = entry.context;
        registry.lock.unlock();
        cancel(context);
    }
}

pub fn cancelDelivery(registry: *NativeCompletionRegistry) void {
    registry.lockRegistry();
    bun.assert(registry.task_scheduled);
    registry.task_scheduled = false;
    registry.lock.unlock();
    defer registry.release();
    registry.close();
}

pub fn run(registry: *NativeCompletionRegistry) void {
    defer registry.release();
    registry.lockRegistry();
    if (!registry.task_scheduled) @panic("native completion delivery ran without a scheduled reference");
    registry.task_scheduled = false;
    const next = if (registry.state == .open) registry.ready_head else null;
    if (next) |entry| {
        registry.ready_head = entry.ready_next;
        if (registry.ready_head == null) registry.ready_tail = null;
        entry.ready_next = null;
        entry.ready = false;
        if (entry.delivery == .once) registry.removeEntry(entry);
        // Deliver one entry per task so callbacks can re-enter the queue.
        registry.scheduleDelivery();
    }
    registry.lock.unlock();
    if (next) |entry| entry.deliver(entry.context);
}

fn removeEntry(registry: *NativeCompletionRegistry, entry: *Entry) void {
    if (!entry.registered) @panic("native completion endpoint removed twice");
    if (entry.previous) |previous| {
        previous.next = entry.next;
    } else {
        registry.entries = entry.next;
    }
    if (entry.next) |next| next.previous = entry.previous;
    entry.previous = null;
    entry.next = null;
    entry.registered = false;
}

fn removeReady(registry: *NativeCompletionRegistry, entry: *Entry) void {
    bun.assert(entry.ready);
    var previous: ?*Entry = null;
    var current = registry.ready_head;
    while (current) |ready| {
        if (ready == entry) {
            if (previous) |parent| parent.ready_next = ready.ready_next else registry.ready_head = ready.ready_next;
            if (registry.ready_tail == ready) registry.ready_tail = previous;
            break;
        }
        previous = ready;
        current = ready.ready_next;
    }
    if (registry.state == .open and current == null)
        @panic("ready native completion endpoint is missing from its queue");
    entry.ready = false;
    entry.ready_next = null;
}

fn lockRegistry(registry: *NativeCompletionRegistry) void {
    while (!registry.lock.tryLock()) std.atomic.spinLoopHint();
}

const std = @import("std");
const bun = @import("bun");
