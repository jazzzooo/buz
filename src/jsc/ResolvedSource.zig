//! The transpiled/loaded form of one module, and the outcome of a module
//! fetch. Native ownership containers: the wire representation is the schema-declared
//! `ResolvedSource` dictionary and `ResolvedSourceResult`
//! union, built at the bindings boundary from these values.

pub const ResolvedSource = struct {
    source_code: bun.String = bun.String.empty,

    /// source_url is eventually deref'd on success
    source_url: bun.String = bun.String.empty,

    is_commonjs_module: bool = false,

    cjs_custom_extension: ?ExtensionCallback = null,

    jsvalue_for_export: ?ExportValue = null,

    tag: Tag = .{ .source = .javascript },

    /// This is for source_code
    source_code_needs_deref: bool = true,
    already_bundled: bool = false,

    bytecode_cache: ?BytecodeCache = null,
    module_info: ?OwnedModuleInfo = null,
    /// The file path used as the source origin for bytecode cache validation.
    /// JSC validates bytecode by checking if the origin URL matches exactly what
    /// was used at build time. If empty, the origin is derived from source_url.
    /// This is converted to a file:// URL on the C++ side.
    bytecode_origin_path: bun.String = bun.String.empty,

    pub const Tag = @FieldType(WireResolvedSource, "tag");
    pub const SourceKind = @FieldType(Tag, "source");
    pub const ExtensionCallback = bun.bindgen.OwnedBrandedValue(
        bun.bindgen.Module("ModuleLoader").nativeExport("prepareCommonJSExtensionUpdate").args[2].ArgumentType.child,
    );
    pub const ExportValue = bun.bindgen.EngineRoot;
    pub const BytecodeCache = union(enum) {
        owned: []u8,
        borrowed: []const u8,

        pub fn deinit(this: *BytecodeCache) void {
            switch (this.*) {
                .owned => |bytes| bun.default_allocator.free(bytes),
                .borrowed => {},
            }
        }
    };
    pub const ModuleInfoHandle = OwnedModuleInfo;

    pub fn deinit(this: *ResolvedSource) void {
        if (this.source_code_needs_deref) this.source_code.deref();
        this.source_code = .empty;
        this.source_url.deref();
        this.source_url = .empty;
        this.bytecode_origin_path.deref();
        this.bytecode_origin_path = .empty;
        if (this.bytecode_cache) |*cache| cache.deinit();
        this.bytecode_cache = null;
        if (this.module_info) |*module_info| module_info.deinit();
        this.module_info = null;
        if (this.cjs_custom_extension) |*extension| extension.deinit();
        this.cjs_custom_extension = null;
        if (this.jsvalue_for_export) |*value| value.deinit();
        this.jsvalue_for_export = null;
    }

    /// Consumes the strings (respecting `source_code_needs_deref`) and
    /// produces the schema dictionary for the wire. `Wire` is the bound
    /// dictionary type of the target declaration.
    pub fn takeWireAs(
        this: *ResolvedSource,
        comptime Wire: type,
        context: anytype,
    ) bun.OOM!Wire {
        errdefer this.deinit();
        var source_code = try takeString(&this.source_code, this.source_code_needs_deref);
        errdefer source_code.deinit();
        var source_url = try takeString(&this.source_url, true);
        errdefer source_url.deinit();
        var bytecode_origin_path = try takeString(&this.bytecode_origin_path, true);
        errdefer bytecode_origin_path.deinit();
        const WireBytecodeCache = @typeInfo(@FieldType(Wire, "bytecodeCache")).optional.child;
        const native_bytecode_cache = this.bytecode_cache;
        this.bytecode_cache = null;
        const bytecode_cache: ?WireBytecodeCache = if (native_bytecode_cache) |cache| bytecode: {
            const resource: struct {
                bytes: []u8,
                release: bun.bindgen.ExternalBytesDeallocator,
            } = switch (cache) {
                .owned => |bytes| .{ .bytes = bytes, .release = freeOwnedBytecode },
                .borrowed => |bytes| .{ .bytes = @constCast(bytes), .release = releaseProcessBytecode },
            };
            if (resource.bytes.len == 0) @panic("bytecode cache cannot be empty");
            break :bytecode WireBytecodeCache.initNative(try bun.bindgen.adoptExternalBytesOwner(
                resource.bytes.ptr,
                resource.bytes.len,
                null,
                resource.release,
            ));
        } else null;
        const WireModuleInfo = @typeInfo(@FieldType(Wire, "moduleInfo")).optional.child;
        if (WireModuleInfo != OwnedModuleInfo) {
            @compileError("resolved-source module ownership must have one schema-derived representation");
        }
        const module_info: ?WireModuleInfo = if (this.module_info) |*value| value.take() else null;
        this.module_info = null;
        const WireExtension = @typeInfo(@FieldType(Wire, "cjsCustomExtension")).optional.child;
        const cjs_custom_extension: ?WireExtension = if (this.cjs_custom_extension) |*callback| extension: {
            const value = callback.takeResult(context);
            this.cjs_custom_extension = null;
            break :extension value;
        } else null;
        const WireExport = @typeInfo(@FieldType(Wire, "jsvalueForExport")).optional.child;
        const jsvalue_for_export: ?WireExport = if (this.jsvalue_for_export) |*export_value| export_value_block: {
            const result = takeEngineValueAs(WireExport, export_value, context);
            this.jsvalue_for_export = null;
            break :export_value_block result;
        } else null;
        return .{
            .sourceCode = source_code,
            .sourceURL = source_url,
            .isCommonJSModule = this.is_commonjs_module,
            .cjsCustomExtension = cjs_custom_extension,
            .jsvalueForExport = jsvalue_for_export,
            .tag = this.tag,
            .alreadyBundled = this.already_bundled,
            .bytecodeCache = bytecode_cache,
            .moduleInfo = module_info,
            .bytecodeOriginPath = bytecode_origin_path,
        };
    }

    fn freeOwnedBytecode(bytes: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        bun.mimalloc.mi_free(bytes);
    }

    fn releaseProcessBytecode(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {}

    fn takeString(string: *bun.String, owned: bool) bun.OOM!bun.bindgen.DOMString {
        defer string.* = .empty;
        if (owned) return bun.bindgen.DOMString.fromBunString(string.*);
        return bun.bindgen.DOMString.fromBunString(string.dupeRef());
    }
};

pub const ResolvedSourceResult = union(enum) {
    value: ResolvedSource,
    err: bun.bindgen.EngineRoot,

    pub fn ok(value: ResolvedSource) ResolvedSourceResult {
        return .{ .value = value };
    }

    pub fn fail(value: bun.bindgen.EngineRoot) ResolvedSourceResult {
        return .{ .err = value };
    }

    pub fn deinit(this: *ResolvedSourceResult) void {
        switch (this.*) {
            .value => |*value| value.deinit(),
            .err => |*value| value.deinit(),
        }
    }

    /// Consumes the result and produces the schema union for the wire.
    pub fn takeWire(this: *ResolvedSourceResult, context: anytype) bun.OOM!WireResolvedSourceResult {
        return this.takeWireAs(WireResolvedSourceResult, context);
    }

    pub fn takeWireAs(
        this: *ResolvedSourceResult,
        comptime Wire: type,
        context: anytype,
    ) bun.OOM!Wire {
        const WireSource = @FieldType(Wire, "value");
        return switch (this.*) {
            .value => |*value| .{ .value = try value.takeWireAs(WireSource, context) },
            .err => |*err_value| .{ .errorValue = takeEngineValueAs(@FieldType(Wire, "errorValue"), err_value, context) },
        };
    }
};

fn takeEngineValueAs(
    comptime Result: type,
    root: *bun.bindgen.EngineRoot,
    context: anytype,
) Result {
    if (Result == bun.bindgen.EngineValueResult) return .fromOwnedRoot(root, context);
    @compileError("resolved-source JS values require a call-scoped engine result");
}

pub const WireResolvedSourceResult = bun.bindgen.Return(FetchBuiltinModuleSchema);
const WireResolvedSource = @FieldType(WireResolvedSourceResult, "value");
pub const OwnedModuleInfo = @typeInfo(@FieldType(WireResolvedSource, "moduleInfo")).optional.child;

const bun = @import("bun");

const ModuleLoaderBindings = bun.bindgen.Module("ModuleLoader");
const FetchBuiltinModuleSchema = ModuleLoaderBindings.nativeExport("fetchBuiltinModule");
