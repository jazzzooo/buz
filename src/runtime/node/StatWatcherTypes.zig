pub const Arguments = struct {
    path: PathLike,
    listener: Listener,
    persistent: bool,
    bigint: bool,
    interval: u32,

    pub fn deinit(this: Arguments) void {
        this.path.deinit();
        var listener = this.listener;
        listener.deinit();
    }
};

const bun = @import("bun");
const bindgen = bun.bindgen;
const PathLike = @import("./types.zig").PathLike;

const StatWatcherSchema = bindgen.Module("StatWatcher").class("StatWatcher");
const StatWatcherConstructorSchema = StatWatcherSchema.constructor();
pub const Listener = bindgen.Callback(StatWatcherConstructorSchema.args[2].ArgumentType);
