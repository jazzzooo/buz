fn resolveFilename(
    context: bun.bindgen.CallContext(ResolveFilenameSchema),
    args: bun.bindgen.Args(ResolveFilenameSchema),
) bun.JSError!bun.bindgen.DOMString {
    const globalThis = context.viewToken().globalObject();
    var bound_specifier = args.specifier.toOwned();
    defer bound_specifier.deinit();
    const specifier = bound_specifier.takeBunString();
    defer specifier.deref();

    var bound_source: ?bun.bindgen.DOMString = if (args.source) |source_input| switch (source_input) {
        .module => |module| try context.engineIn("NodeModuleModule", "commonJSModuleSourceFilename").call(.{ .module = module.operand(context) }),
        .string => |value| value.toOwned(),
        .object => |object| source: {
            if (object.filename) |filename| break :source filename.toOwned();
            const id = (try object.id.convert(context)).value;
            break :source if (id) |value| value.toOwned() else null;
        },
        .ignored => null,
    } else null;
    defer if (bound_source) |*value| value.deinit();
    const source = if (bound_source) |*value| value.takeBunString() else bun.String.empty;
    defer source.deref();

    const resolved_options = if (args.options) |options| try options.convert(context) else null;
    const paths_view = if (resolved_options) |input| switch (input.value) {
        .options => |options| options.paths,
        .ignored => null,
    } else null;
    if (paths_view) |paths_input| {
        return bun.api.Bun.resolveStringWithPaths(globalThis, specifier, source, false, true, paths_input);
    }

    return bun.api.Bun.resolveString(globalThis, specifier, source, false, true, true);
}

fn findPath(
    context: bun.bindgen.CallContext(FindPathSchema),
    args: bun.bindgen.Args(FindPathSchema),
) bun.JSError!bun.bindgen.Return(FindPathSchema) {
    const globalThis = context.viewToken().globalObject();
    var stack_buf_buffer: [8192]u8 = undefined;
    var stack_buf: std.heap.BufferFirstAllocator = .init(&stack_buf_buffer, bun.default_allocator);
    const alloc = stack_buf.allocator();

    const request_slice = try args.request.toUTF8(alloc);
    defer request_slice.deinit();
    const request = request_slice.slice();
    var request_value = try bun.bindgen.DOMString.fromUTF8(request);
    const request_bun_str = request_value.takeBunString();
    defer request_bun_str.deref();

    const absolute_request = std.fs.path.isAbsolute(request);
    var found = switch (args.paths) {
        .paths => |paths| found: {
            for (0..paths.len()) |index| {
                var path = paths.at(index).?.toOwned();
                defer path.deinit();
                var cur_path = path.takeBunString();
                defer cur_path.deref();

                if (try findPathInner(globalThis, request_bun_str, cur_path)) |resolved| {
                    break :found resolved;
                }
            }
            break :found null;
        },
        .ignored => if (absolute_request)
            try findPathInner(globalThis, request_bun_str, bun.String.static(""))
        else
            return .{ .boolean = false },
    };

    if (found) |*resolved| {
        return .{ .string = resolved.take() };
    }

    return .{ .boolean = false };
}

fn findPathInner(
    globalThis: *bun.jsc.JSGlobalObject,
    request: bun.String,
    cur_path: bun.String,
) bun.JSError!?bun.bindgen.DOMString {
    const resolved = try bun.jsc.VirtualMachine.findModuleSpecifier(globalThis, request, cur_path) orelse return null;
    return try bun.bindgen.DOMString.fromBunString(resolved);
}

pub fn _stat(
    context: bun.bindgen.CallContext(StatSchema),
    args: bun.bindgen.Args(StatSchema),
) bun.JSError!i32 {
    _ = context;
    const path = try args.path.toUTF8(bun.default_allocator);
    defer path.deinit();
    const exists = bun.sys.existsAtType(.cwd(), path.slice()).unwrap() catch
        return -1; // Returns a negative integer for any other kind of strings.
    return switch (exists) {
        .file => 0, // Returns 0 for files.
        .directory => 1, // Returns 1 for directories.
    };
}

fn bindPrepareCommonJSExtensionUpdate(
    context: bun.bindgen.CallContext(PrepareCommonJSExtensionSchema),
    args: bun.bindgen.Args(PrepareCommonJSExtensionSchema),
) bun.JSError!bun.bindgen.Return(PrepareCommonJSExtensionSchema) {
    return bun.jsc.ModuleLoader.prepareCommonJSExtensionUpdate(context, args);
}

fn bindFinishCommonJSExtensionUpdate(
    args: *bun.bindgen.Args(FinishCommonJSExtensionSchema),
) bun.bindgen.Return(FinishCommonJSExtensionSchema) {
    bun.jsc.ModuleLoader.finishCommonJSExtensionUpdate(args);
}

comptime {
    _ = ResolveFilenameBinding;
    _ = StatBinding;
    _ = FindPathBinding;
    _ = PrepareCommonJSExtensionBinding;
    _ = FinishCommonJSExtensionBinding;
}

const bun = @import("bun");
const std = @import("std");

const NodeModuleBindings = bun.bindgen.Module("NodeModuleModule");
const ResolveFilenameSchema = NodeModuleBindings.function("resolveFilename");
const StatSchema = NodeModuleBindings.function("_stat");
const FindPathSchema = NodeModuleBindings.function("_findPath");
const ResolveFilenameBinding = bun.bindgen.Fn(ResolveFilenameSchema, resolveFilename);
const StatBinding = bun.bindgen.Fn(StatSchema, _stat);
const FindPathBinding = bun.bindgen.Fn(FindPathSchema, findPath);
const ModuleLoaderBindings = bun.bindgen.Module("ModuleLoader");
const PrepareCommonJSExtensionSchema = ModuleLoaderBindings.nativeExport("prepareCommonJSExtensionUpdate");
const FinishCommonJSExtensionSchema = ModuleLoaderBindings.nativeExport("finishCommonJSExtensionUpdate");
const PrepareCommonJSExtensionBinding = bun.bindgen.Fn(PrepareCommonJSExtensionSchema, bindPrepareCommonJSExtensionUpdate);
const FinishCommonJSExtensionBinding = bun.bindgen.Fn(FinishCommonJSExtensionSchema, bindFinishCommonJSExtensionUpdate);
