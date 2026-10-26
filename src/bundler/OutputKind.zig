pub const OutputKind = enum {
    chunk,
    asset,
    @"entry-point",
    sourcemap,
    bytecode,
    module_info,
    @"metafile-json",
    @"metafile-markdown",

    pub fn isFileInStandaloneMode(this: OutputKind) bool {
        return this != .sourcemap and this != .bytecode and this != .module_info and this != .@"metafile-json" and this != .@"metafile-markdown";
    }
};
