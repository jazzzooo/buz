const bun = @import("bun");

pub const SocketFailure = union(enum) {
    value: bun.bindgen.AnyResult,
    system: bun.sys.Error,
    invalid_duplex_data,
};
