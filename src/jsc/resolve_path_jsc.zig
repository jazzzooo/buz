//! Native binding that joins a path against the VM's cwd; `paths/` is JSC-free.
//! Referenced from `PathInlines.h`.

fn bindResolvePathFromCwd(
    _: bun.bindgen.CallContext(ResolvePathFromCwdSchema),
    args: bun.bindgen.Args(ResolvePathFromCwdSchema),
) bun.JSError!bun.bindgen.Return(ResolvePathFromCwdSchema) {
    const str = try args.input.toUTF8(bun.default_allocator);
    defer str.deinit();

    const cwd = bun.jsc.VirtualMachine.get().transpiler.fs.top_level_dir;
    var sfa_buffer: [4096]u8 = undefined;
    var sfa: std.heap.BufferFirstAllocator = .init(&sfa_buffer, bun.default_allocator);
    const alloc = sfa.allocator();
    const buf = try alloc.alloc(u8, cwd.len + str.slice().len + 2);
    defer alloc.free(buf);

    const out_slice = bun.path.joinAbsStringBuf(
        cwd,
        buf,
        &.{str.slice()},
        .auto,
    );

    return bun.bindgen.DOMString.fromUTF8(out_slice);
}

comptime {
    _ = ResolvePathFromCwdBinding;
}

const bun = @import("bun");
const std = @import("std");
const PathBindings = bun.bindgen.Module("Path");
const ResolvePathFromCwdSchema = PathBindings.nativeExport("resolvePathFromCwd");
const ResolvePathFromCwdBinding = bun.bindgen.Fn(ResolvePathFromCwdSchema, bindResolvePathFromCwd);
