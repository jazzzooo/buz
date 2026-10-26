pub fn capabilities(transpiler: Transpiler.EngineCapabilities) CliEngineCapabilities {
    return .{
        .transpiler = transpiler,
        .configure_process_runtime = configureProcessRuntime,
        .run_repl = runRepl,
        .run_tests = runTests,
        .build_watch = BuildCommandEngine.build_watch_factory,
    };
}

pub fn configureProcessRuntime(no_deprecation: bool, throw_deprecation: bool, zero_fill_buffers: bool) void {
    if (no_deprecation) bun.bindgen.Engine(ProcessSetNoDeprecationSchema).call(.{ .value = true });
    if (throw_deprecation) bun.bindgen.Engine(ProcessSetThrowDeprecationSchema).call(.{ .value = true });
    if (zero_fill_buffers) bun.bindgen.Engine(ProcessSetZeroFillBuffersSchema).call(.{ .value = true });
}

fn runRepl(context: CommandContext) anyerror!void {
    return ReplCommand.exec(context);
}

fn runTests(context: CommandContext) anyerror!void {
    return TestCommand.exec(context);
}

const bun = @import("bun");
const Transpiler = bun.Transpiler;
const CliEngineCapabilities = @import("../options_types/Context.zig").EngineCapabilities;
const CommandContext = @import("../options_types/Context.zig").Context;
const BuildCommandEngine = @import("./BuildCommandEngine.zig");
pub const ReplCommandEngine = @import("./repl_command.zig");
const ReplCommand = ReplCommandEngine.ReplCommand;
const TestCommand = @import("./test_command.zig").TestCommand;

const ProcessBindings = bun.bindgen.Module("Process");
const ProcessSetZeroFillBuffersSchema = ProcessBindings.engineShim("setZeroFillBuffers");
const ProcessSetNoDeprecationSchema = ProcessBindings.engineShim("setProcessNoDeprecation");
const ProcessSetThrowDeprecationSchema = ProcessBindings.engineShim("setProcessThrowDeprecation");
