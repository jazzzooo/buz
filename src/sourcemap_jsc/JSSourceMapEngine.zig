pub fn lookup(source_url: []const u8) bun.OOM!?ParsedSourceMapRef {
    const source_map = try bun.jsc.VirtualMachine.get().source_mappings.get(source_url) orelse return null;
    return .adopt(source_map);
}

const bun = @import("bun");
const ParsedSourceMapRef = bun.bindgen.RefNative(bun.SourceMap.ParsedSourceMap, .any);
