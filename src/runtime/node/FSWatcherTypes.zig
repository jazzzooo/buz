pub const Arguments = struct {
    path: PathLike,
    listener: Listener,
    signal: ?*bun.webcore.AbortSignal,
    persistent: bool,
    recursive: bool,
    encoding: NodeEncoding,
    verbose: bool,

    pub fn deinit(this: Arguments) void {
        this.path.deinit();
        var listener = this.listener;
        listener.deinit();
    }
};

pub const NodeEncoding = @import("./types.zig").Encoding;

const bun = @import("bun");
const bindgen = bun.bindgen;
const PathLike = @import("./types.zig").PathLike;

const FSWatcherSchema = bindgen.Module("FSWatcher").class("FSWatcher");
const FSWatcherConstructorSchema = FSWatcherSchema.constructor();
pub const Listener = bindgen.Callback(FSWatcherConstructorSchema.args[2].ArgumentType);
pub const ListenerArgs = bindgen.Args(FSWatcherConstructorSchema.args[2].ArgumentType);
pub const ListenerEvent = @FieldType(ListenerArgs, "eventType");
pub const ListenerValue = @FieldType(ListenerArgs, "value");
