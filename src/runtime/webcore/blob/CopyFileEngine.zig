pub const Task = jsc.WorkTask(copy_file.CopyFile);

pub fn start(global: *jsc.JSGlobalObject, destination: StoreRange, source: StoreRange, completion: copy_file.CopyFileCompletion, mkdirp: bool, mode: ?bun.Mode) bun.OOM!void {
    if (comptime bun.Environment.isWindows) {
        const Operation = @import("./CopyFileUV.zig");
        const Endpoint = @import("../../../event_loop/NativeIOEndpoint.zig").NativeIOEndpoint(Operation, copy_file.CopyFileResult);
        const vm = global.bunVM();
        const endpoint = try Endpoint.create(vm, completion.context, completion.callback);
        errdefer endpoint.deinitUnstarted();
        const operation = try Operation.create(vm.uvLoop(), destination, source, .{
            .context = endpoint,
            .callback = Endpoint.receive,
        }, mkdirp, mode);
        endpoint.start(operation);
        return;
    }
    const operation = try copy_file.CopyFile.create(destination, source, completion, mkdirp, mode);
    errdefer operation.deinitUnscheduled();
    const task = try Task.createOnJSThread(global, operation);
    task.schedule();
}

const copy_file = @import("./copy_file.zig");
const StoreRange = @import("./StoreRange.zig");

const bun = @import("bun");
const jsc = bun.jsc;
