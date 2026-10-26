fn compilerArtifactDestroy(args: bun.bindgen.Args(CompilerArtifactDestroySchema)) bun.bindgen.Return(CompilerArtifactDestroySchema) {
    args.moduleInfo.deinit();
}

fn compilerArtifactToModuleRecord(
    context: bun.bindgen.CallContext(CompilerArtifactSchema),
    args: bun.bindgen.Args(CompilerArtifactSchema),
) bun.JSError!bun.bindgen.Return(CompilerArtifactSchema) {
    const res = args.moduleInfo;
    res.validate() catch return null;
    const allocator = bun.default_allocator;

    const create_module_record = context.engineIn("compiler_module_records", "compilerModuleRecordCreate");
    const CreateArgs = @TypeOf(create_module_record).Args;
    const Identifier = std.meta.Child(@FieldType(CreateArgs, "identifiers"));
    const Declaration = std.meta.Child(@FieldType(CreateArgs, "declarations"));
    const RequestedModule = std.meta.Child(@FieldType(CreateArgs, "requestedModules"));
    const Import = std.meta.Child(@FieldType(CreateArgs, "imports"));
    const Export = std.meta.Child(@FieldType(CreateArgs, "exports"));

    const owned_identifiers = try allocator.alloc(bun.bindgen.DOMString, res.strings_lens.len);
    defer allocator.free(owned_identifiers);
    const identifiers = try allocator.alloc(Identifier, res.strings_lens.len);
    defer allocator.free(identifiers);
    var initialized_identifiers: usize = 0;
    defer for (owned_identifiers[0..initialized_identifiers]) |*identifier| identifier.deinit();

    var offset: usize = 0;
    for (0.., res.strings_lens) |index, len| {
        const sub = res.strings_buf[offset..][0..len];
        owned_identifiers[index] = try bun.bindgen.DOMString.fromUTF8(sub);
        initialized_identifiers += 1;
        identifiers[index] = owned_identifiers[index].operand();
        offset += len;
    }

    var declarations = std.array_list.Managed(Declaration).init(allocator);
    defer declarations.deinit();
    var imports = std.array_list.Managed(Import).init(allocator);
    defer imports.deinit();
    var exports = std.array_list.Managed(Export).init(allocator);
    defer exports.deinit();

    var i: usize = 0;
    for (res.record_kinds) |kind| {
        const record_len = kind.len() catch unreachable;
        switch (kind) {
            .declared_variable => try declarations.append(.{ .kind = .Declared, .identifier = stringID(res.buffer[i]) }),
            .lexical_variable => try declarations.append(.{ .kind = .Lexical, .identifier = stringID(res.buffer[i]) }),
            .import_info_single => try imports.append(.{
                .kind = .Single,
                .moduleName = stringID(res.buffer[i]),
                .importName = stringID(res.buffer[i + 1]),
                .localName = stringID(res.buffer[i + 2]),
            }),
            .import_info_single_type_script => try imports.append(.{
                .kind = .SingleTypeScript,
                .moduleName = stringID(res.buffer[i]),
                .importName = stringID(res.buffer[i + 1]),
                .localName = stringID(res.buffer[i + 2]),
            }),
            .import_info_namespace => try imports.append(.{
                .kind = .Namespace,
                .moduleName = stringID(res.buffer[i]),
                .importName = stringID(res.buffer[i + 1]),
                .localName = stringID(res.buffer[i + 2]),
            }),
            .export_info_indirect => try exports.append(if (res.buffer[i + 1] == .star_namespace) .{
                .kind = .Namespace,
                .exportName = stringID(res.buffer[i]),
                .importName = 0,
                .localName = 0,
                .moduleName = stringID(res.buffer[i + 2]),
            } else .{
                .kind = .Indirect,
                .exportName = stringID(res.buffer[i]),
                .importName = stringID(res.buffer[i + 1]),
                .localName = 0,
                .moduleName = stringID(res.buffer[i + 2]),
            }),
            .export_info_local => try exports.append(.{
                .kind = .Local,
                .exportName = stringID(res.buffer[i]),
                .importName = 0,
                .localName = stringID(res.buffer[i + 1]),
                .moduleName = 0,
            }),
            .export_info_namespace => try exports.append(.{
                .kind = .Namespace,
                .exportName = stringID(res.buffer[i]),
                .importName = 0,
                .localName = 0,
                .moduleName = stringID(res.buffer[i + 1]),
            }),
            .export_info_star => try exports.append(.{
                .kind = .Star,
                .exportName = 0,
                .importName = 0,
                .localName = 0,
                .moduleName = stringID(res.buffer[i]),
            }),
            else => unreachable,
        }
        i += record_len;
    }
    var requested_modules = try std.array_list.Managed(RequestedModule).initCapacity(allocator, res.requested_modules_keys.len);
    defer requested_modules.deinit();
    for (res.requested_modules_keys, res.requested_modules_values) |module_name, kind| {
        try requested_modules.append(.{
            .kind = switch (kind) {
                .none => .None,
                .javascript => .JavaScript,
                .webassembly => .WebAssembly,
                .json => .JSON,
                else => .HostDefined,
            },
            .moduleName = stringID(module_name),
            .hostDefinedImportType = switch (kind) {
                .none, .javascript, .webassembly, .json => 0,
                else => |host_defined| @intCast(@backingInt(host_defined)),
            },
        });
    }

    return try create_module_record.call(.{
        .moduleKey = args.moduleKey,
        .sourceCode = args.sourceCode,
        .declaredVariables = args.declaredVariables,
        .lexicalVariables = args.lexicalVariables,
        .identifiers = identifiers,
        .declarations = declarations.items,
        .requestedModules = requested_modules.items,
        .imports = imports.items,
        .exports = exports.items,
        .hasImportMeta = res.flags.contains_import_meta,
        .isTypeScript = res.flags.is_typescript,
        .hasTLA = res.flags.has_tla,
    });
}

fn stringID(value: StringID) u32 {
    return @intCast(@backingInt(value));
}

const std = @import("std");

const bun = @import("bun");
const analyze = @import("../bundler/analyze_transpiled_module.zig");
const ModuleInfoDeserialized = analyze.ModuleInfoDeserialized;
const StringID = analyze.StringID;

const CompilerBindings = bun.bindgen.Module("compiler_module_records");
const CompilerArtifactDestroySchema = CompilerBindings.nativeExport("compilerArtifactDestroy");
const CompilerArtifactSchema = CompilerBindings.nativeExport("compilerArtifactToModuleRecord");
const CompilerArtifactDestroyBinding = bun.bindgen.Fn(CompilerArtifactDestroySchema, compilerArtifactDestroy);
const CompilerArtifactBinding = bun.bindgen.Fn(CompilerArtifactSchema, compilerArtifactToModuleRecord);

comptime {
    _ = CompilerArtifactDestroyBinding;
    _ = CompilerArtifactBinding;
}
