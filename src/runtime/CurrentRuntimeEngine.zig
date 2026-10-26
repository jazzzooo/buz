const std = @import("std");

const bun = @import("bun");
const jsc = bun.jsc;

pub fn io() std.Io {
    return jsc.VirtualMachine.get().io;
}

pub fn backgroundTasks() *bun.BackgroundTaskGroup {
    return &jsc.VirtualMachine.get().background_tasks;
}

pub fn fillEntropy(destination: []u8) void {
    jsc.VirtualMachine.get().rareData().fillEntropy(destination);
}

pub fn nextUUID() bun.UUID {
    return jsc.VirtualMachine.get().rareData().nextUUID();
}

pub fn defaultCSRFSecret() bun.OOM![]const u8 {
    return jsc.VirtualMachine.get().rareData().defaultCSRFSecret();
}

pub fn garbageCollect(sync: bool) usize {
    return jsc.VirtualMachine.get().garbageCollect(sync);
}

pub fn configureGarbageCollectionAggression(value: ?i32) i32 {
    const vm = jsc.VirtualMachine.get();
    const previous: i32 = @backingInt(vm.aggressive_garbage_collection);
    if (value) |level| vm.aggressive_garbage_collection = switch (level) {
        1 => .mild,
        2 => .aggressive,
        0 => .none,
        else => return previous,
    };
    return previous;
}

pub fn dumpAllocatorStats() void {
    jsc.VirtualMachine.get().arena.dumpStats();
}

pub fn shrinkFootprint(context: anytype) void {
    context.viewToken().globalObject().vm().shrinkFootprint();
}

pub fn readOriginTimer() u64 {
    return jsc.VirtualMachine.get().origin_timer.read();
}

pub fn boringEngine() *bun.BoringSSL.c.ENGINE {
    return jsc.VirtualMachine.get().rareData().boringEngine();
}

pub fn nodeCryptoBackend() @import("./node/NodeCryptoBackend.zig").Backend {
    return @import("./node/NodeCryptoEngine.zig").backend();
}

pub fn tlsRejectUnauthorized() bool {
    return jsc.VirtualMachine.get().getTLSRejectUnauthorized();
}

pub fn createProcessArgv(context: anytype) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
    return @import("./node/NodeProcessEngine.zig").createArgvForContext(context);
}

pub fn setProcessWorkingDirectory(context: anytype, path: bun.bindgen.DOMStringView) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
    return @import("./node/NodeProcessEngine.zig").setCwdForContext(context, path);
}

pub fn exitProcess(code: u8) void {
    @import("./node/NodeProcessEngine.zig").exitProcess(code);
}

pub fn createProcessExecArgv(context: anytype) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
    return @import("./node/NodeProcessEngine.zig").createExecArgvForContext(context);
}

pub fn getProcessEval(context: anytype) bun.bindgen.CallError(@TypeOf(context))!bun.bindgen.Return(@TypeOf(context)) {
    return @import("./node/NodeProcessEngine.zig").getEvalForContext(context);
}
