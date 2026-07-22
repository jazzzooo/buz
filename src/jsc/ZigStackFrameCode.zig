pub const ZigStackFrameCode = enum(u8) {
    None = 0,
    /// 🏃
    Eval = 1,
    /// 📦
    Module = 2,
    /// λ
    Function = 3,
    /// 🌎
    Global = 4,
    /// ⚙️
    Wasm = 5,
    /// 👷
    Constructor = 6,
    _,

    pub fn emoji(this: ZigStackFrameCode) u21 {
        return switch (this) {
            .Eval => 0x1F3C3,
            .Module => 0x1F4E6,
            .Function => 0x03BB,
            .Global => 0x1F30E,
            .Wasm => 0xFE0F,
            .Constructor => 0xF1477,
            else => ' ',
        };
    }
};
