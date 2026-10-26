//! Headers inspection through JavaScript property lookup and console formatting.

pub const inspect = bun.jsc.ConsoleObject.formatClassRefForBinding;

const bun = @import("bun");
