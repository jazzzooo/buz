pub const ResolveMessage = struct {
    bindgen_state: bindgen.ClassState = .{},
    message: logger.OwnedMessage,
    referrer: logger.OwnedMessage.Bytes,
    logged: bool = false,

    const Methods = @import("./DiagnosticFormatting.zig").BindingMethods(ResolveMessage, ResolveMessageSchema, "ResolveMessage");

    pub const Binding = ResolveMessageClass;
    pub const Ref = bindgen.ClassRef(ResolveMessageSchema);

    pub fn loggerMessage(this: *const ResolveMessage) *const logger.OwnedMessage {
        return &this.message;
    }

    pub fn createRef(
        global: *JSGlobalObject,
        msg: logger.Msg,
        referrer: string,
    ) bun.JSError!Ref {
        const native = try createNative(msg, referrer);
        return ResolveMessageClass.adoptNativeRef(native, global);
    }

    pub fn createNative(
        msg: logger.Msg,
        referrer: string,
    ) bun.OOM!*ResolveMessage {
        const native = try default_allocator.create(ResolveMessage);
        errdefer default_allocator.destroy(native);
        var message = try logger.OwnedMessage.copy(msg);
        errdefer message.deinit();
        native.* = .{
            .message = message,
            .referrer = try logger.OwnedMessage.copyBytes(referrer),
        };
        return native;
    }

    pub fn adoptResult(native: *ResolveMessage, context: anytype) bun.JSError!Ref {
        return ResolveMessageClass.adoptResult(native, context);
    }

    pub fn getCode(
        this: *ResolveMessage,
        _: bindgen.CallContext(ResolveMessageCodeSchema),
        _: bindgen.Args(ResolveMessageCodeSchema),
    ) bun.JSError!?bindgen.DOMString {
        const msg = &this.message;
        switch (msg.metadata) {
            .resolve => |resolve| {
                const specifier = resolve.specifier.slice(msg.data.text.slice());
                const code = switch (resolve.import_kind) {
                    .require => if (bun.strings.hasPrefixComptime(specifier, "node:"))
                        "ERR_UNKNOWN_BUILTIN_MODULE"
                    else
                        "MODULE_NOT_FOUND",
                    .require_resolve => "MODULE_NOT_FOUND",
                    .stmt, .dynamic => if (bun.strings.hasPrefixComptime(specifier, "node:"))
                        "ERR_UNKNOWN_BUILTIN_MODULE"
                    else
                        "ERR_MODULE_NOT_FOUND",
                    .html_manifest,
                    .entry_point_run,
                    .entry_point_build,
                    .at,
                    .at_conditional,
                    .url,
                    .internal,
                    .composes,
                    => "RESOLVE_ERROR",
                };
                return try bindgen.DOMString.fromUTF8(code);
            },
            else => return null,
        }
    }

    pub const getColumn = Methods.getColumn;

    pub const getLine = Methods.getLine;

    pub fn fmt(
        allocator: std.mem.Allocator,
        specifier: string,
        referrer: string,
        err: anyerror,
        import_kind: bun.ImportKind,
    ) !string {
        if (import_kind != .require_resolve and bun.strings.hasPrefixComptime(specifier, "node:")) {
            return try std.fmt.allocPrint(allocator, "No such built-in module: {s}", .{specifier});
        }
        switch (err) {
            error.ModuleNotFound => {
                if (strings.eqlComptime(referrer, "bun:main")) {
                    return try std.fmt.allocPrint(allocator, "Module not found '{s}'", .{specifier});
                }
                if (resolver.isPackagePath(specifier) and !strings.containsChar(specifier, '/')) {
                    return try std.fmt.allocPrint(allocator, "Cannot find package '{s}' from '{s}'", .{ specifier, referrer });
                }
                return try std.fmt.allocPrint(allocator, "Cannot find module '{s}' from '{s}'", .{ specifier, referrer });
            },
            error.InvalidDataURL => return try std.fmt.allocPrint(
                allocator,
                "Cannot resolve invalid data URL '{s}' from '{s}'",
                .{ specifier, referrer },
            ),
            error.InvalidURL => return try std.fmt.allocPrint(
                allocator,
                "Cannot resolve invalid URL '{s}' from '{s}'",
                .{ specifier, referrer },
            ),
            else => {
                if (resolver.isPackagePath(specifier)) {
                    return try std.fmt.allocPrint(
                        allocator,
                        "{s} while resolving package '{s}' from '{s}'",
                        .{ @errorName(err), specifier, referrer },
                    );
                }
                return try std.fmt.allocPrint(
                    allocator,
                    "{s} while resolving '{s}' from '{s}'",
                    .{ @errorName(err), specifier, referrer },
                );
            },
        }
    }

    pub const toString = Methods.toString;

    pub const inspectCustom = Methods.inspectCustom;

    pub const toPrimitive = Methods.toPrimitive;

    pub fn toJSON(
        this: *ResolveMessage,
        _: bindgen.CallContext(ResolveMessageToJSONSchema),
        _: bindgen.Args(ResolveMessageToJSONSchema),
    ) bun.JSError!bindgen.Return(ResolveMessageToJSONSchema) {
        const msg = &this.message;
        var name = try bindgen.DOMString.fromUTF8("ResolveMessage");
        errdefer name.deinit();
        var message = try bindgen.DOMString.fromUTF8(msg.data.text.slice());
        errdefer message.deinit();
        var specifier = try bindgen.DOMString.fromUTF8(msg.metadata.resolve.specifier.slice(msg.data.text.slice()));
        errdefer specifier.deinit();
        var import_kind = try bindgen.DOMString.fromUTF8(msg.metadata.resolve.import_kind.label());
        errdefer import_kind.deinit();
        var referrer = try bindgen.DOMString.fromUTF8(this.referrer.slice());
        errdefer referrer.deinit();
        return .{
            .name = name,
            .position = try bun.api.BuildMessage.generatePosition(msg.data.view().location),
            .message = message,
            .level = this.level(),
            .specifier = specifier,
            .import_kind = import_kind,
            .referrer = @as(?bindgen.DOMString, referrer),
        };
    }

    pub const getPosition = Methods.getPosition;

    pub const getMessage = Methods.getMessage;

    pub const getLevel = Methods.getLevel;

    const level = Methods.level;

    pub fn getSpecifier(
        this: *ResolveMessage,
        _: bindgen.CallContext(ResolveMessageSpecifierSchema),
        _: bindgen.Args(ResolveMessageSpecifierSchema),
    ) bun.JSError!bindgen.DOMString {
        const msg = &this.message;
        return bindgen.DOMString.fromUTF8(msg.metadata.resolve.specifier.slice(msg.data.text.slice()));
    }

    pub fn getImportKind(
        this: *ResolveMessage,
        _: bindgen.CallContext(ResolveMessageImportKindSchema),
        _: bindgen.Args(ResolveMessageImportKindSchema),
    ) bun.JSError!bindgen.DOMString {
        return bindgen.DOMString.fromUTF8(this.message.metadata.resolve.import_kind.label());
    }

    pub fn getReferrer(
        this: *ResolveMessage,
        _: bindgen.CallContext(ResolveMessageReferrerSchema),
        _: bindgen.Args(ResolveMessageReferrerSchema),
    ) bun.JSError!?bindgen.DOMString {
        return try bindgen.DOMString.fromUTF8(this.referrer.slice());
    }

    pub const destroy = deinit;

    fn deinit(this: *ResolveMessage) void {
        this.message.deinit();
        this.referrer.deinit();
        default_allocator.destroy(this);
    }
};

const string = []const u8;

const resolver = bun.resolver;
const std = @import("std");

const bun = @import("bun");
const default_allocator = bun.default_allocator;
const logger = bun.logger;
const strings = bun.strings;

const jsc = bun.jsc;
const bindgen = bun.bindgen;
const JSGlobalObject = jsc.JSGlobalObject;

const ResolveMessageBindingModule = bindgen.Module("ResolveMessage");
const ResolveMessageSchema = ResolveMessageBindingModule.class("ResolveMessage");
const ResolveMessageCodeSchema = ResolveMessageSchema.member("code");
const ResolveMessageImportKindSchema = ResolveMessageSchema.member("importKind");
const ResolveMessageReferrerSchema = ResolveMessageSchema.member("referrer");
const ResolveMessageSpecifierSchema = ResolveMessageSchema.member("specifier");
const ResolveMessageToJSONSchema = ResolveMessageSchema.member("toJSON");
const ResolveMessageClass = bindgen.Class(ResolveMessageSchema, ResolveMessage);

comptime {
    _ = ResolveMessageClass;
}
