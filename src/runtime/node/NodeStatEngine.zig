pub const OwnedStats = StatsObject.OwnedInstance;

pub fn createOwned(
    global: *bun.jsc.JSGlobalObject,
    stats: *const bun.sys.PosixStat,
    bigint: bool,
) bun.JSError!OwnedStats {
    var scope: bun.bindgen.FocusedEngineScope = undefined;
    scope.init(global);
    defer scope.deinit();
    if (bigint) {
        const value = stat.StatsBig.init(stats);
        const fields = value.toResult(BigIntStatsObject.Fields);
        return BigIntStatsObject.createOwned(&scope, &fields);
    }
    const value = stat.StatsSmall.init(stats);
    const fields = value.toResult(StatsObject.Fields);
    return StatsObject.createOwned(&scope, &fields);
}

pub fn constructorResult(
    context: bun.bindgen.CallContext(NodeJSFSStatsSchema),
) StatsObject.ConstructorResult {
    return StatsObject.constructorResult(context);
}

const bun = @import("bun");
const stat = @import("./Stat.zig");
const NodeFSStatModule = bun.bindgen.Module("NodeFSStat");
const StatsObject = bun.bindgen.PlainObject(NodeFSStatModule.class("Stats"));
const BigIntStatsObject = bun.bindgen.PlainObject(NodeFSStatModule.class("BigIntStats"));
const NodeJSFSStatsSchema = bun.bindgen.Module("NodeJSFS").class("NodeJSFS").member("Stats");
