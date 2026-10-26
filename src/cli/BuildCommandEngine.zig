const BuildWatcher = jsc.hot_reloader.NewHotReloader(BuildWatchSession, jsc.EventLoop, true, true);

pub const build_watch_factory: BuildWatchSession.Factory = .{
    .create = create,
};

fn create(transpiler: *bun.Transpiler) *BuildWatchSession {
    const state = bun.new(State, undefined);
    const clear_screen = !transpiler.env.hasSetNoClearTerminalOnReload(!bun.Output.enable_ansi_colors_stdout);
    state.session = .{
        .transpiler = transpiler,
        .watcher = undefined,
        .clear_screen = clear_screen,
        .backend = .{
            .context = .init(state),
            .vtable = &backend_vtable,
        },
    };
    state.reloader = BuildWatcher.init(
        &state.session,
        transpiler.fs,
        transpiler.log.level.atLeast(.info),
        clear_screen,
        null,
    );
    state.session.watcher = state.reloader.watcher;
    transpiler.resolver.watcher = state.reloader.watcher.getResolveWatcher();
    return &state.session;
}

const State = struct {
    session: BuildWatchSession,
    reloader: *BuildWatcher,
};

const backend_vtable: BuildWatchSession.Backend.VTable = .{
    .deinit = struct {
        fn deinit(context: BuildWatchSession.Backend.Context) void {
            const state = context.get(*State);
            state.reloader.deinit(bun.Watcher.requires_file_descriptors);
            bun.destroy(state);
        }
    }.deinit,
    .wait_for_reload = struct {
        fn waitForReload(context: BuildWatchSession.Backend.Context, io: std.Io) BuildWatchSession.WatchOutcome {
            const state = context.get(*State);
            return switch (state.reloader.waitForReload(io)) {
                .waiting => .waiting,
                .reload => .reload,
                .failed => .failed,
            };
        }
    }.waitForReload,
};

const std = @import("std");
const bun = @import("bun");
const jsc = bun.jsc;
const BuildWatchSession = @import("./BuildWatchSession.zig");
