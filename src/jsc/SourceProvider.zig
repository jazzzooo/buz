/// Opaque representation of a JavaScript source provider
pub const SourceProvider = opaque {
    pub fn deref(provider: *SourceProvider) void {
        bun.bindgen.Engine(DerefSchema).call(.{ .provider = @ptrCast(provider) });
    }
};

const bun = @import("bun");
const DerefSchema = bun.bindgen.Module("source_providers").engineShim("sourceProviderDeref");
