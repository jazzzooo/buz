pub fn forEventLoop(loop: *jsc.EventLoop) RuntimeLoop {
    return RuntimeLoop.fromJavaScript(
        .init(loop),
        jsc.EventLoopHandle.init(loop).parentEventLoop(),
        &runtime_loop_vtable,
    );
}

pub const javascript_semantics = jsc.JavaScriptSemanticsEngine.javascript_semantics;

const runtime_loop_vtable = RuntimeLoop.JavaScript.VTable{
    .iteration_number = struct {
        fn call(context: RuntimeLoop.JavaScript.Context) u64 {
            const loop = context.get(*jsc.EventLoop);
            return loop.usocketsLoop().iterationNumber();
        }
    }.call,
    .file_polls = struct {
        fn call(context: RuntimeLoop.JavaScript.Context) bun.OOM!*bun.Async.FilePoll.Store {
            const loop = context.get(*jsc.EventLoop);
            const rare = try loop.virtual_machine.tryRareData();
            return rare.tryFilePolls(loop.virtual_machine);
        }
    }.call,
    .put_file_poll = struct {
        fn call(context: RuntimeLoop.JavaScript.Context, poll: *bun.Async.FilePoll) void {
            const loop = context.get(*jsc.EventLoop);
            loop.virtual_machine.rareData().filePolls(loop.virtual_machine).put(
                poll,
                loop.virtual_machine,
                poll.flags.contains(.was_ever_registered),
            );
        }
    }.call,
    .loop = struct {
        fn call(context: RuntimeLoop.JavaScript.Context) *bun.uws.Loop {
            const loop = context.get(*jsc.EventLoop);
            return loop.virtual_machine.uwsLoop();
        }
    }.call,
    .pipe_read_buffer = struct {
        fn call(context: RuntimeLoop.JavaScript.Context) []u8 {
            const loop = context.get(*jsc.EventLoop);
            return loop.pipeReadBuffer();
        }
    }.call,
    .tick = struct {
        fn call(context: RuntimeLoop.JavaScript.Context, state: *anyopaque, is_done: *const fn (*anyopaque) bool) void {
            const loop = context.get(*jsc.EventLoop);
            while (!is_done(state)) {
                loop.tick();
                loop.autoTick();
            }
        }
    }.call,
    .tick_once = struct {
        fn call(context: RuntimeLoop.JavaScript.Context) void {
            const loop = context.get(*jsc.EventLoop);
            loop.tick();
            loop.autoTickActive();
        }
    }.call,
};

const bun = @import("bun");
const jsc = bun.jsc;
const RuntimeLoop = @import("../event_loop/RuntimeLoop.zig").RuntimeLoop;
