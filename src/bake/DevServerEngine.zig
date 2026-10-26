pub fn adoptResponseForRejection(
    response: *bun.webcore.Response,
    global: *jsc.JSGlobalObject,
) bun.JSError!bindgen.Root {
    var reference = try response.toClassRef(global);
    return reference.takeAnyRoot();
}

pub const ConcurrentTask = jsc.ConcurrentTask;

pub fn hotReloadTask(context: anytype) ConcurrentTask {
    return .{ .task = jsc.Task.init(context) };
}

const bun = @import("bun");
const jsc = bun.jsc;
const bindgen = bun.bindgen;
