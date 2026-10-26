pub var initialized = false;

pub fn initialize() void {
    if (initialized) return;
    initialized = true;
    js_ast.Expr.Data.Store.create();
    js_ast.Stmt.Data.Store.create();
}

const js_ast = bun.ast;

const bun = @import("bun");
