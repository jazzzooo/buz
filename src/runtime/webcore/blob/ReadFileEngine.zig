const Core = @import("./read_file.zig");

pub const Task = jsc.WorkTask(Core.ReadFile);

pub fn startUV(
    event_loop: *jsc.EventLoop,
    store: *Core.Store,
    offset: Core.SizeType,
    max_length: Core.SizeType,
    comptime Handler: type,
    handler: *anyopaque,
) bun.OOM!void {
    const Endpoint = @import("../../../event_loop/NativeIOEndpoint.zig").NativeIOEndpoint(Core.ReadFileUV, Core.ReadFileResultType);
    const vm = event_loop.virtual_machine;
    const endpoint = try Endpoint.create(vm, handler, Handler.run);
    errdefer endpoint.deinitUnstarted();
    const operation = try Core.ReadFileUV.create(vm.uvLoop(), store, offset, max_length, .{
        .context = endpoint,
        .callback = Endpoint.receive,
    });
    endpoint.start(operation);
}

const bun = @import("bun");
const jsc = bun.jsc;
