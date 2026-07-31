pub const version = "17.0.0";
pub const max_code_point = 0x10ffff;

pub const GraphemeBreak = enum(u4) {
    other,
    control,
    cr,
    lf,
    extend,
    regional_indicator,
    prepend,
    spacing_mark,
    l,
    v,
    t,
    lv,
    lvt,
    zwj,
};

pub const IndicConjunctBreak = enum(u2) {
    none,
    consonant,
    extend,
    linker,
};

pub const Width = enum(u2) {
    zero,
    narrow,
    wide,
    ambiguous,
};

pub const Properties = packed struct(u16) {
    grapheme_break: GraphemeBreak = .other,
    indic_conjunct_break: IndicConjunctBreak = .none,
    width: Width = .narrow,
    emoji: bool = false,
    extended_pictographic: bool = false,
    emoji_modifier: bool = false,
    _padding: u5 = 0,
};
