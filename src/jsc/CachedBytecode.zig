pub const CachedBytecode = struct {
    release_allocator: bun.allocators.ReleaseAllocator,
    resource: CachedBytecodeResource,

    pub fn generateForESM(sourceProviderURL: *bun.String, input: []const u8) ?*CachedBytecode {
        return generateKind(sourceProviderURL, input, .esm);
    }

    pub fn generateForCJS(sourceProviderURL: *bun.String, input: []const u8) ?*CachedBytecode {
        return generateKind(sourceProviderURL, input, .cjs);
    }

    pub fn deref(this: *CachedBytecode) void {
        this.release_allocator.release();
    }

    fn release(release_allocator: *bun.allocators.ReleaseAllocator) void {
        const this: *CachedBytecode = @fieldParentPtr("release_allocator", release_allocator);
        this.resource.deinit();
        bun.default_allocator.destroy(this);
    }

    pub fn generate(format: bun.options.Format, input: []const u8, source_provider_url: *bun.String) ?*CachedBytecode {
        return switch (format) {
            .esm => generateForESM(source_provider_url, input),
            .cjs => generateForCJS(source_provider_url, input),
            else => null,
        };
    }

    pub fn allocator(this: *CachedBytecode) std.mem.Allocator {
        return this.release_allocator.allocator();
    }

    pub fn bytes(this: *const CachedBytecode) []const u8 {
        return this.resource.slice();
    }

    fn generateKind(source_provider_url: *bun.String, input: []const u8, kind: CachedBytecodeKind) ?*CachedBytecode {
        var url = bun.bindgen.ThreadSafeDOMString.fromBunString(source_provider_url.dupeRef()) catch bun.outOfMemory();
        defer url.deinit();

        var owner = bun.bindgen.Engine(GenerateCachedBytecodeSchema).call(.{
            .sourceProviderURL = url.operand(),
            .source = bun.bindgen.BytesOperand.fromSlice(input),
            .kind = kind,
        }) orelse return null;
        var resource = owner.takeByteResource();
        const this = bun.default_allocator.create(CachedBytecode) catch {
            resource.deinit();
            bun.outOfMemory();
        };
        this.* = .{
            .release_allocator = .init(release),
            .resource = resource.take(),
        };
        return this;
    }
};

const bun = @import("bun");
const std = @import("std");
const CachedBytecodeBindings = bun.bindgen.Module("cached_bytecode");
const GenerateCachedBytecodeSchema = CachedBytecodeBindings.engineShim("generateCachedBytecode");
const CachedBytecodeKind = @FieldType(bun.bindgen.Args(GenerateCachedBytecodeSchema), "kind");
const CachedBytecodeOwner = @typeInfo(bun.bindgen.Return(GenerateCachedBytecodeSchema)).optional.child;
const CachedBytecodeResource = CachedBytecodeOwner.ByteResource;
