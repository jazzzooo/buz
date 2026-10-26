//! Blob and File inspection through the console's engine formatter.

pub const inspect = bun.jsc.ConsoleObject.formatClassRefForBinding;

const bun = @import("bun");
