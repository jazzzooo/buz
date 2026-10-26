const bun = @import("bun");

pub fn runSetup(
    context: anytype,
    plugin: anytype,
    setup: anytype,
    config: anytype,
    is_first: bool,
    is_last: bool,
    is_bake: bool,
) bun.JSError!void {
    var plugin_result = (try context.engineIn("JSBundlerPlugin", "runSetupFunction").call(.{
        .plugin = plugin.operand(context),
        .setupFunction = setup.operand(context),
        .config = if (comptime @TypeOf(config) == @TypeOf(null)) null else config.operand(context),
        .isFirst = is_first,
        .isLast = is_last,
        .isBake = is_bake,
    })) orelse return;
    defer plugin_result.deinit();

    var promise = try plugin_result.toOwned();
    defer promise.deinit();
    if (try context.waitForPromiseRejection(promise.operand(context).asPromise())) |reason| {
        var rejection = reason;
        defer rejection.deinit();
        return rejection.throwException(context);
    }
}
