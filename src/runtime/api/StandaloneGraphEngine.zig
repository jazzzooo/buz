//! Engine bridges for `StandaloneModuleGraph.File`. The graph itself stays in
//! `standalone_graph/` because the bundler uses it without a JS engine.

pub fn fileBlob(this: *const File) bun.OOM!bun.webcore.Blob {
    const store = try bun.webcore.Blob.Store.initExecutable(this.executableBytes());
    var blob = try bun.webcore.Blob.initWithStore(store);
    errdefer blob.deinit();
    if (bun.http.MimeType.byExtensionNoDefault(bun.strings.trimLeadingChar(std.fs.path.extension(this.name), '.'))) |mime| {
        try blob.setContentType(mime.value, .inferred);
        store.mime_type = mime;
    }
    if (strings.hasPrefixComptime(this.name, bun.StandaloneModuleGraph.base_public_path_with_default_suffix)) {
        blob.name = try bun.bindgen.ThreadSafeDOMString.fromUTF8(this.name[bun.StandaloneModuleGraph.base_public_path_with_default_suffix.len..]);
    } else if (this.name.len > 0) {
        blob.name = try bun.bindgen.ThreadSafeDOMString.fromUTF8(this.name);
    }
    return blob;
}

const std = @import("std");

const bun = @import("bun");
const strings = bun.strings;
const File = bun.StandaloneModuleGraph.File;
