pub const BuildMessage = struct {
    bindgen_state: bindgen.ClassState = .{},
    message: logger.OwnedMessage,
    logged: bool = false,

    const Methods = @import("./DiagnosticFormatting.zig").BindingMethods(BuildMessage, BuildMessageSchema, "BuildMessage");

    pub const Binding = BuildMessageClass;
    pub const Ref = bindgen.ClassRef(BuildMessageSchema);

    pub fn loggerMessage(this: *const BuildMessage) *const logger.OwnedMessage {
        return &this.message;
    }

    pub fn createRef(
        global: *jsc.JSGlobalObject,
        msg: logger.Msg,
    ) bun.JSError!Ref {
        const native = try createNative(msg);
        return BuildMessageClass.adoptNativeRef(native, global);
    }

    pub fn createNative(
        msg: logger.Msg,
    ) bun.OOM!*BuildMessage {
        const native = try default_allocator.create(BuildMessage);
        errdefer default_allocator.destroy(native);
        native.* = .{
            .message = try logger.OwnedMessage.copy(msg),
        };
        return native;
    }

    pub fn adoptResult(native: *BuildMessage, context: anytype) bun.JSError!Ref {
        return BuildMessageClass.adoptResult(native, context);
    }

    pub fn getNotes(
        this: *BuildMessage,
        context: bindgen.CallContext(BuildMessageNotesSchema),
        _: bindgen.Args(BuildMessageNotesSchema),
    ) bun.JSError!bindgen.Return(BuildMessageNotesSchema) {
        const Result = bindgen.Return(BuildMessageNotesSchema);
        const notes = this.message.notes.slice();
        var builder = try Result.Builder.init(notes.len);
        errdefer builder.deinit();
        for (notes) |*note| {
            const native = try BuildMessage.createNative(.{ .data = note.view(), .kind = .note });
            builder.appendOwned(try BuildMessage.adoptResult(native, context));
        }
        return builder.finish();
    }

    pub const toString = Methods.toString;

    pub const inspectCustom = Methods.inspectCustom;

    pub const toPrimitive = Methods.toPrimitive;

    pub fn toJSON(
        this: *BuildMessage,
        _: bindgen.CallContext(BuildMessageToJSONSchema),
        _: bindgen.Args(BuildMessageToJSONSchema),
    ) bun.JSError!bindgen.Return(BuildMessageToJSONSchema) {
        var name = try bindgen.DOMString.fromUTF8("BuildMessage");
        errdefer name.deinit();
        var message = try bindgen.DOMString.fromUTF8(this.message.data.text.slice());
        errdefer message.deinit();
        return .{
            .name = name,
            .position = try generatePosition(this.message.data.view().location),
            .message = message,
            .level = this.level(),
        };
    }

    pub fn generatePosition(value: ?logger.Location) bun.OOM!bindgen.Return(BuildMessagePositionSchema) {
        const location = value orelse return null;
        var line_text = try bindgen.DOMString.fromUTF8(location.line_text orelse "");
        errdefer line_text.deinit();
        var file = try bindgen.DOMString.fromUTF8(location.file);
        errdefer file.deinit();
        var namespace = try bindgen.DOMString.fromUTF8(location.namespace);
        errdefer namespace.deinit();
        return .{
            .line_text = line_text,
            .file = file,
            .namespace_value = namespace,
            .line = location.line,
            .column = location.column,
            .length = location.length,
            .offset = location.offset,
        };
    }

    pub const getColumn = Methods.getColumn;

    pub const getLine = Methods.getLine;

    pub const getPosition = Methods.getPosition;

    pub const getMessage = Methods.getMessage;

    pub const getLevel = Methods.getLevel;

    const level = Methods.level;

    pub const destroy = deinit;

    fn deinit(this: *BuildMessage) void {
        this.message.deinit();
        default_allocator.destroy(this);
    }
};

const bun = @import("bun");
const default_allocator = bun.default_allocator;
const logger = bun.logger;

const jsc = bun.jsc;
const bindgen = bun.bindgen;

const BuildMessageBindingModule = bindgen.Module("BuildMessage");
const BuildMessageSchema = BuildMessageBindingModule.class("BuildMessage");
const BuildMessageNotesSchema = BuildMessageSchema.member("notes");
const BuildMessagePositionSchema = BuildMessageSchema.member("position");
const BuildMessageToJSONSchema = BuildMessageSchema.member("toJSON");
const BuildMessageClass = bindgen.Class(BuildMessageSchema, BuildMessage);

comptime {
    _ = BuildMessageClass;
}
