const b = @import("bindgen_schema");

const engine_shims = .{
    b.engineShim("closeAllSQLiteDatabasesForTermination", .{}, b.none, .current_realm_unchecked),
};

pub const schema = b.moduleWithEngineShims("sqlite_termination", .{}, engine_shims);
