pub fn Dispatcher(comptime Plugin: type) type {
    return struct {
        const Self = @This();
        const RefCount = bun.ptr.ThreadSafeRefCount(Self, "ref_count", destroy, .{});
        pub const ref = RefCount.ref;
        pub const deref = RefCount.deref;

        ref_count: RefCount = .init(),
        queue_mutex: std.atomic.Mutex = .unlocked,
        state_mutex: std.atomic.Mutex = .unlocked,
        state_readers: std.atomic.Value(usize) = .init(0),
        closed: bool = false,
        registry: *jsc.NativeCompletionRegistry,
        entry: jsc.NativeCompletionRegistry.Entry = undefined,
        head: ?*Request = null,
        tail: ?*Request = null,
        active_head: ?*Active = null,

        /// VM-thread registration owning one reference to a pending reaction.
        pub const Active = struct {
            previous: ?*Active = null,
            next: ?*Active = null,
            registered: bool = false,
            context: bun.bindgen.NativeCallbackContext(.vm),
            cancellation: *const Cancellation,
            cancel: *const fn (bun.bindgen.NativeCallbackContext(.vm)) void,
        };

        const Endpoint = struct {
            plugin: *Plugin,
            control: *Self,

            fn deliver(raw: bun.bindgen.NativeCallbackContext(.vm)) void {
                const endpoint = raw.get(*Endpoint);
                const control = endpoint.control;
                const plugin = endpoint.plugin;
                control.ref();
                defer control.deref();
                plugin.ref();
                defer plugin.deinit();
                const request = control.pop() orelse return;
                if (request.build().isCancelRequested()) {
                    request.cancel();
                    return;
                }
                switch (request.take()) {
                    .load => |load| plugin.matchOnLoad(load.path, load.namespace, load, load.default_loader, load.bakeGraph() != .client),
                    .resolve => |resolve| plugin.matchOnResolve(
                        resolve.import_record.specifier,
                        resolve.import_record.namespace,
                        resolve.import_record.source_file,
                        resolve,
                        resolve.import_record.kind,
                    ),
                }
            }

            fn detach(raw: bun.bindgen.NativeCallbackContext(.vm)) void {
                const endpoint = raw.get(*Endpoint);
                const control = endpoint.control;
                while (!control.state_mutex.tryLock()) std.atomic.spinLoopHint();
                control.lockQueue();
                control.closed = true;
                var current = control.head;
                control.head = null;
                control.tail = null;
                control.queue_mutex.unlock();
                control.state_mutex.unlock();
                while (control.state_readers.load(.acquire) != 0) std.atomic.spinLoopHint();
                bun.destroy(endpoint);
                while (current) |request| {
                    current = request.next;
                    request.next = null;
                    request.cancel();
                }
                while (control.active_head) |active| {
                    const removed = control.removeActive(active);
                    bun.assert(removed);
                    active.cancel(active.context);
                }
                control.deref();
            }
        };

        pub fn create(plugin: *Plugin, vm: *jsc.VirtualMachine) bun.OOM!*Self {
            const registry = try (try vm.tryRareData()).nativeCompletionRegistry(vm);
            const control = try bun.tryNew(Self, .{ .registry = registry });
            errdefer bun.destroy(control);
            const endpoint = try bun.tryNew(Endpoint, .{ .plugin = plugin, .control = control });
            registry.retain();
            control.entry = .{
                .context = .init(endpoint),
                .deliver = Endpoint.deliver,
                .detach = Endpoint.detach,
                .delivery = .repeating,
            };
            control.ref();
            if (!registry.register(&control.entry)) Endpoint.detach(.init(endpoint));
            return control;
        }

        pub fn post(this: *Self, request: *Request) void {
            this.lockQueue();
            bun.assert(request.state == .idle and request.next == null);
            request.state = .queued;
            if (this.closed or request.build().isCancelRequested()) {
                this.queue_mutex.unlock();
                request.cancel();
                return;
            }
            if (this.tail) |tail| tail.next = request else this.head = request;
            this.tail = request;
            _ = this.registry.notify(&this.entry);
            this.queue_mutex.unlock();
        }

        fn pop(this: *Self) ?*Request {
            this.lockQueue();
            defer this.queue_mutex.unlock();
            const request = this.head orelse return null;
            this.head = request.next;
            request.next = null;
            if (this.head == null) this.tail = null else _ = this.registry.notify(&this.entry);
            return request;
        }

        pub fn addActive(this: *Self, active: *Active) bool {
            this.lockQueue();
            defer this.queue_mutex.unlock();
            if (this.closed or active.cancellation.isRequested()) return false;
            bun.assert(!active.registered);
            active.previous = null;
            active.next = this.active_head;
            if (this.active_head) |head| head.previous = active;
            this.active_head = active;
            active.registered = true;
            return true;
        }

        pub fn removeActive(this: *Self, active: *Active) bool {
            if (!active.registered) return false;
            if (active.previous) |previous| previous.next = active.next else this.active_head = active.next;
            if (active.next) |next| next.previous = active.previous;
            active.previous = null;
            active.next = null;
            active.registered = false;
            return true;
        }

        pub fn cancelBuild(this: *Self, cancellation: *Cancellation) void {
            cancellation.request();
            this.ref();
            defer this.deref();
            this.lockQueue();
            var previous: ?*Request = null;
            var current = this.head;
            var cancelled_head: ?*Request = null;
            var cancelled_tail: ?*Request = null;
            while (current) |request| {
                current = request.next;
                if (request.build().cancellationToken() != cancellation) {
                    previous = request;
                    continue;
                }
                if (previous) |parent| parent.next = request.next else this.head = request.next;
                if (this.tail == request) this.tail = previous;
                request.next = null;
                if (cancelled_tail) |tail| tail.next = request else cancelled_head = request;
                cancelled_tail = request;
            }
            this.queue_mutex.unlock();
            while (cancelled_head) |request| {
                cancelled_head = request.next;
                request.next = null;
                request.cancel();
            }
            while (true) {
                var active = this.active_head;
                while (active) |entry| {
                    if (entry.cancellation == cancellation) break;
                    active = entry.next;
                }
                const entry = active orelse break;
                const removed = this.removeActive(entry);
                bun.assert(removed);
                entry.cancel(entry.context);
            }
        }

        pub fn lockState(this: *Self) bool {
            while (!this.state_mutex.tryLock()) std.atomic.spinLoopHint();
            defer this.state_mutex.unlock();
            if (this.closed) {
                return false;
            }
            const readers = this.state_readers.fetchAdd(1, .monotonic);
            if (readers == std.math.maxInt(usize)) @panic("plugin state reader count overflowed");
            return true;
        }

        pub fn unlockState(this: *Self) void {
            const readers = this.state_readers.fetchSub(1, .release);
            bun.assert(readers > 0);
        }

        pub fn close(this: *Self) void {
            this.registry.detach(&this.entry);
        }

        fn lockQueue(this: *Self) void {
            while (!this.queue_mutex.tryLock()) std.atomic.spinLoopHint();
        }

        fn destroy(this: *Self) void {
            bun.assert(this.closed and this.head == null and this.tail == null and this.active_head == null);
            bun.assert(this.state_readers.load(.acquire) == 0);
            this.registry.release();
            bun.destroy(this);
        }
    };
}

const std = @import("std");
const bun = @import("bun");
const jsc = bun.jsc;
const Request = @import("../bundler/PluginHost.zig").Request;
const Cancellation = @import("../bundler/Cancellation.zig");
