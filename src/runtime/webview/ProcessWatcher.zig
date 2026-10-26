const ProcessWatcher = @This();

pub const Kind = enum { chrome, webkit };

vm: *jsc.VirtualMachine,
kind: Kind,
generation: u64,
control: *Control,

const Control = struct {
    references: std.atomic.Value(usize) = .init(1),
    lock: std.atomic.Mutex = .unlocked,
    pid: std.posix.pid_t,
    registry: *jsc.NativeCompletionRegistry,
    entry: jsc.NativeCompletionRegistry.Entry,
    signal: i32 = 0,

    fn ref(self: *Control) void {
        _ = self.references.fetchAdd(1, .monotonic);
    }

    fn deref(self: *Control) void {
        if (self.references.fetchSub(1, .acq_rel) != 1) return;
        self.registry.release();
        bun.destroy(self);
    }

    fn kill(self: *Control) void {
        if (comptime bun.Environment.isWindows) return;
        // The waiter holds this lock only after exit or while cleaning up a wait failure.
        if (!self.lock.tryLock()) return;
        defer self.lock.unlock();
        if (self.pid != 0)
            _ = std.c.kill(self.pid, std.posix.SIG.KILL);
    }

    fn run(self: *Control) void {
        const observed = c.bun_wait_child_exit(self.pid);
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
        var result = bun.spawn.waitpid(self.pid, if (observed == 0) 0 else std.posix.W.NOHANG);
        if (result == .result and result.result.pid == 0) {
            _ = std.c.kill(self.pid, std.posix.SIG.KILL);
            result = bun.spawn.waitpid(self.pid, 0);
        }
        self.pid = 0;
        if (result == .result and std.posix.W.IFSIGNALED(result.result.status))
            self.signal = @intCast(@backingInt(std.posix.W.TERMSIG(result.result.status)));
        self.lock.unlock();
        _ = self.registry.submit(&self.entry);
        self.deref();
    }
};

// Takes responsibility for reaping pid, including on preparation failure.
pub fn start(vm: *jsc.VirtualMachine, kind: Kind, generation: u64, pid: std.posix.pid_t) !*ProcessWatcher {
    var owns_pid = true;
    errdefer if (owns_pid) {
        _ = std.c.kill(pid, std.posix.SIG.KILL);
        _ = bun.spawn.waitpid(pid, 0);
    };
    const self = try prepare(vm, kind, generation, pid);
    const control = self.control;
    control.ref();
    const thread = std.Thread.spawn(.{}, Control.run, .{control}) catch |err| {
        owns_pid = false;
        control.registry.detach(&control.entry);
        Control.run(control);
        return err;
    };
    owns_pid = false;
    slot(vm, kind).* = self;
    thread.detach();
    return self;
}

fn prepare(vm: *jsc.VirtualMachine, kind: Kind, generation: u64, pid: std.posix.pid_t) !*ProcessWatcher {
    const registry = try (try vm.tryRareData()).nativeCompletionRegistry(vm);
    const self = try bun.default_allocator.create(ProcessWatcher);
    errdefer bun.destroy(self);
    const control = try bun.default_allocator.create(Control);
    errdefer bun.destroy(control);
    registry.retain();
    errdefer registry.release();
    self.* = .{ .vm = vm, .kind = kind, .generation = generation, .control = control };
    control.* = .{
        .pid = pid,
        .registry = registry,
        .entry = .{
            .context = .init(self),
            .deliver = deliver,
            .detach = detach,
            .cancel = cancel,
        },
    };
    if (!registry.register(&control.entry)) return error.VMClosed;
    return self;
}

pub fn kill(self: *ProcessWatcher) void {
    self.control.kill();
}

fn slot(vm: *jsc.VirtualMachine, kind: Kind) *?*ProcessWatcher {
    const rare = vm.rare_data.?;
    return switch (kind) {
        .chrome => &rare.webview_chrome_process,
        .webkit => &rare.webview_host_process,
    };
}

fn release(self: *ProcessWatcher) void {
    const registration = slot(self.vm, self.kind);
    if (registration.* == self) registration.* = null;
    self.control.entry.context = .init(self.control);
    self.control.deref();
    bun.destroy(self);
}

fn deliver(pointer: bun.bindgen.NativeCallbackContext(.vm)) void {
    const self = pointer.get(*ProcessWatcher);
    const vm = self.vm;
    const kind = self.kind;
    const generation = self.generation;
    const signal = self.control.signal;
    self.release();
    switch (kind) {
        .chrome => bun.bindgen.Engine(ChromeDiedSchema).call(vm.global, .{ .signo = signal, .generation = generation }),
        .webkit => bun.bindgen.Engine(WebKitDiedSchema).call(vm.global, .{ .signo = signal, .generation = generation }),
    }
}

fn cancel(pointer: bun.bindgen.NativeCallbackContext(.vm)) void {
    const self = pointer.get(*ProcessWatcher);
    self.kill();
}

fn detach(pointer: bun.bindgen.NativeCallbackContext(.vm)) void {
    const self = pointer.get(*ProcessWatcher);
    self.kill();
    self.release();
}

const std = @import("std");
const bun = @import("bun");
const jsc = bun.jsc;
const c = @import("libc-spawn");
const ChromeDiedSchema = bun.bindgen.Module("ChromeProcess").engineShim("chromeProcessDied");
const WebKitDiedSchema = bun.bindgen.Module("WebViewHostProcess").engineShim("webViewHostProcessDied");
