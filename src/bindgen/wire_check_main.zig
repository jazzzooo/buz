const doc = @import("document.zig");

comptime {
    const document: doc.Binding = @import("binding_ir");
    @import("wire_check.zig").validate(document.wire_types, @import("binding_wire"));
}
