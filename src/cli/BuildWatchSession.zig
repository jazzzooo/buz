const BuildWatchSession = @This();

transpiler: *Transpiler,
watcher: *bun.Watcher,
clear_screen: bool,
backend: Backend,

pub const WatchOutcome = enum(u8) {
    waiting,
    reload,
    failed,
};

pub const Backend = struct {
    pub const Context = bun.bindgen.NativeCallbackContext(.vm);
    context: Context,
    vtable: *const VTable,

    pub const VTable = struct {
        deinit: *const fn (Context) void,
        wait_for_reload: *const fn (Context, std.Io) WatchOutcome,
    };
};

pub const Factory = struct {
    create: *const fn (*Transpiler) *BuildWatchSession,
};

pub const Attachment = struct {
    factory: Factory,
    session: *?*BuildWatchSession,

    pub fn attach(context: bun.bindgen.NativeCallbackContext(.vm), transpiler: *Transpiler) *bun.Watcher {
        const attachment = context.get(*Attachment);
        const session = attachment.factory.create(transpiler);
        attachment.session.* = session;
        return session.watcher;
    }
};

pub fn deinit(this: *BuildWatchSession) void {
    this.transpiler.resolver.watcher = null;
    this.backend.vtable.deinit(this.backend.context);
}

pub fn waitForReload(this: *BuildWatchSession, io: std.Io) WatchOutcome {
    return this.backend.vtable.wait_for_reload(this.backend.context, io);
}

pub fn getLoaders(this: *BuildWatchSession) *bun.options.Loader.HashTable {
    return &this.transpiler.options.loaders;
}

pub fn bustDirCache(this: *BuildWatchSession, path: []const u8) bool {
    return this.transpiler.resolver.bustDirCache(path);
}

const std = @import("std");
const bun = @import("bun");
const Transpiler = bun.Transpiler;
