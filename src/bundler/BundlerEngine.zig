pub fn prepareBytecodeGeneration() void {
    jsc.VirtualMachine.is_bundler_thread_for_bytecode_cache = true;
    jsc.initialize(false);
}

pub const bytecode_generator: BytecodeGenerator = .{
    .generate_fn = generateBytecode,
};

fn generateBytecode(format: bun.options.Format, source: []const u8, source_provider_url: *bun.String) ?BytecodeGenerator.Generated {
    prepareBytecodeGeneration();
    const owner = jsc.CachedBytecode.generate(format, source, source_provider_url) orelse return null;
    return .{
        .bytes = owner.bytes(),
        .allocator = owner.allocator(),
    };
}

pub fn forEventLoop(loop: *jsc.EventLoop) ResultDispatcher.Factory {
    return @import("../bundler_jsc/ResultDispatcherEngine.zig").factory(loop);
}

const bun = @import("bun");
const jsc = bun.jsc;
const BytecodeGenerator = @import("./BytecodeGenerator.zig");
const ResultDispatcher = @import("./ResultDispatcher.zig");
