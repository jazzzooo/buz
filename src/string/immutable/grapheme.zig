pub const BreakState = enum(u3) {
    default,
    regional_indicator,
    extended_pictographic,
    extended_pictographic_zwj,
    indic_consonant,
    indic_linker,
};

/// Returns whether `cp2` starts a new grapheme; sequential calls must reuse `state`, initialized to `.default`.
pub fn graphemeBreak(cp1: u32, cp2: u32, state: *BreakState) bool {
    const first = unicode.get(cp1);
    const second = unicode.get(cp2);
    const context = if (state.* == .default) seedContext(first) else state.*;
    const result = isBreak(first, second, context);
    state.* = nextContext(first.grapheme_break, second, context, result);
    return result;
}

fn isBreak(first: Properties, second: Properties, context: BreakState) bool {
    const first_break = first.grapheme_break;
    const second_break = second.grapheme_break;

    if (first_break == .cr and second_break == .lf) return false;
    if (isControl(first_break) or isControl(second_break)) return true;

    if (first_break == .l and switch (second_break) {
        .l, .v, .lv, .lvt => true,
        else => false,
    }) return false;
    if ((first_break == .lv or first_break == .v) and
        (second_break == .v or second_break == .t))
    {
        return false;
    }
    if ((first_break == .lvt or first_break == .t) and second_break == .t)
        return false;

    if (second_break == .extend or second_break == .zwj) return false;
    if (second_break == .spacing_mark) return false;
    if (first_break == .prepend) return false;

    if (context == .indic_linker and second.indic_conjunct_break == .consonant)
        return false;
    if (context == .extended_pictographic_zwj and second.extended_pictographic)
        return false;

    if (first_break == .regional_indicator and second_break == .regional_indicator)
        return context == .regional_indicator;

    return true;
}

fn nextContext(
    first_break: unicode.GraphemeBreak,
    second: Properties,
    context: BreakState,
    did_break: bool,
) BreakState {
    if (did_break) return seedContext(second);
    if (first_break == .regional_indicator and second.grapheme_break == .regional_indicator)
        return .regional_indicator;

    switch (context) {
        .regional_indicator => {},
        .extended_pictographic => switch (second.grapheme_break) {
            .extend => return .extended_pictographic,
            .zwj => return .extended_pictographic_zwj,
            else => {},
        },
        .extended_pictographic_zwj => {
            if (second.extended_pictographic) return .extended_pictographic;
        },
        .indic_consonant => switch (second.indic_conjunct_break) {
            .extend => return .indic_consonant,
            .linker => return .indic_linker,
            else => {},
        },
        .indic_linker => switch (second.indic_conjunct_break) {
            .extend, .linker => return .indic_linker,
            .consonant => return .indic_consonant,
            .none => {},
        },
        .default => {},
    }
    return seedContext(second);
}

fn seedContext(properties: Properties) BreakState {
    if (properties.extended_pictographic) return .extended_pictographic;
    if (properties.indic_conjunct_break == .consonant) return .indic_consonant;
    return .default;
}

fn isControl(value: unicode.GraphemeBreak) bool {
    return switch (value) {
        .control, .cr, .lf => true,
        else => false,
    };
}

const unicode = @import("unicode_data");
const Properties = unicode.Properties;
