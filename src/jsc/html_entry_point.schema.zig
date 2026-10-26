const b = @import("bindgen_schema");

const engine_shims = .{
    b.engineShim("loadHTMLEntryPoint", .{}, b.js_promise, .current_realm_nonthrowing),
};

pub const schema = b.moduleWithEngineShims("html_entry_point", .{}, engine_shims);
