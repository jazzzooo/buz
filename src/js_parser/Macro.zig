pub const namespace: string = "macro";
pub const namespaceWithColon: string = namespace ++ ":";

pub fn isMacroPath(path: string) bool {
    return strings.hasPrefixComptime(path, namespaceWithColon);
}

pub const Context = opaque {
    pub const Operations = struct {
        destroy: *const fn (*Context) void,
        get_remap: *const fn (*const Context, string) ?MacroRemapEntry,
        set_javascript_object: *const fn (*Context, *const bun.bindgen.Root) void,
        call: *const fn (
            *Context,
            std.mem.Allocator,
            import_record_path: string,
            source_dir: string,
            log: *logger.Log,
            source: *const logger.Source,
            import_range: logger.Range,
            caller: Expr,
            function_name: string,
        ) anyerror!Expr,
    };

    pub const Header = struct {
        operations: *const Operations,
    };

    pub fn destroy(this: *Context) void {
        operationTable(this).destroy(this);
    }

    pub fn getRemap(this: *const Context, path: string) ?MacroRemapEntry {
        return operationTable(this).get_remap(this, path);
    }

    pub fn setJavascriptObject(this: *Context, root: *const bun.bindgen.Root) void {
        operationTable(this).set_javascript_object(this, root);
    }

    pub fn call(
        this: *Context,
        allocator: std.mem.Allocator,
        import_record_path: string,
        source_dir: string,
        log: *logger.Log,
        source: *const logger.Source,
        import_range: logger.Range,
        caller: Expr,
        function_name: string,
    ) anyerror!Expr {
        return operationTable(this).call(
            this,
            allocator,
            import_record_path,
            source_dir,
            log,
            source,
            import_range,
            caller,
            function_name,
        );
    }

    fn operationTable(this: *const Context) *const Operations {
        const header: *const Header = @ptrCast(@alignCast(this));
        return header.operations;
    }
};

const string = []const u8;

const bun = @import("bun");
const std = @import("std");
const strings = bun.strings;
const logger = @import("../logger/logger.zig");
const MacroRemapEntry = @import("../resolver/package_json.zig").MacroImportReplacementMap;
const Expr = @import("./ast/Expr.zig");
