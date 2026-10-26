pub fn toBuildArtifact(this: *OutputFile, owned_pathname: []u8) bun.OOM!?*BuildArtifact {
    var input = (try Conversion.takeBuildArtifact(this, owned_pathname)) orelse return null;
    defer input.deinit();

    const artifact = try bun.default_allocator.create(BuildArtifact);
    errdefer bun.default_allocator.destroy(artifact);
    const blob = try createBlob(&input.source);
    artifact.* = .{
        .blob = blob,
        .hash = input.hash,
        .loader = input.loader,
        .output_kind = input.output_kind,
        .path = .fromDefaultAllocatedSlice(input.takePath()),
    };
    return artifact;
}

pub fn toBlob(this: *OutputFile, allocator: std.mem.Allocator) !Blob {
    var source = try Conversion.takeBlob(this, allocator);
    defer source.deinit();
    return createBlob(&source);
}

fn createBlob(source: *Conversion.BlobSource) !Blob {
    return switch (source.*) {
        .empty => unreachable,
        .file => {
            const file = source.takeFile();
            const store = try Blob.Store.initFile(file.pathlike, file.mime_type, file.allocator);
            return Blob.initWithStore(store);
        },
        .buffer => {
            const buffer = source.takeBuffer();
            var blob = try Blob.init(@constCast(buffer.bytes), buffer.allocator);
            errdefer blob.deinit();
            if (blob.storePtr()) |store| store.mime_type = buffer.mime_type;
            try blob.setContentType(buffer.mime_type.value, .inferred);
            return blob;
        },
    };
}

const OutputFile = @import("../bundler/OutputFile.zig");
const std = @import("std");
const bun = @import("bun");
const jsc = bun.jsc;
const Blob = jsc.WebCore.Blob;
const BuildArtifact = jsc.API.BuildArtifact;
const Conversion = @import("../bundler/OutputFileConversion.zig");
