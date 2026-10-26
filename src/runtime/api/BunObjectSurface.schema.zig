const b = @import("bindgen_schema");
const archive = @import("binding_schema_Archive");
const bun_object = @import("binding_schema_BunObject");
const csrf = @import("binding_schema_CSRFObject");
const crypto_hasher = @import("binding_schema_CryptoHasher");
const cron_job = @import("binding_schema_CronJob");
const ffi = @import("binding_schema_FFI");
const file_system_router = @import("binding_schema_FileSystemRouter");
const glob = @import("binding_schema_Glob");
const hash = @import("binding_schema_HashObject");
const image = @import("binding_schema_Image");
const json5 = @import("binding_schema_JSON5Object");
const jsonc = @import("binding_schema_JSONCObject");
const js_sink = @import("binding_schema_JSSink");
const markdown = @import("binding_schema_MarkdownObject");
const node_dns = @import("binding_schema_NodeDNS");
const password = @import("binding_schema_PasswordObject");
const redis_client = @import("binding_schema_RedisClient");
const runtime = @import("binding_schema_RuntimeFunctions");
const s3_client = @import("binding_schema_S3Client");
const secrets = @import("binding_schema_Secrets");
const semver = @import("binding_schema_SemverObject");
const static_hashers = @import("binding_schema_StaticCryptoHashers");
const string_width = @import("binding_schema_StringWidth");
const surface_builtins = @import("binding_schema_SurfaceBuiltins");
const terminal = @import("binding_schema_Terminal");
const toml = @import("binding_schema_TOMLObject");
const transpiler = @import("binding_schema_Transpiler");
const unsafe_object = @import("binding_schema_UnsafeObject");
const web_view = @import("binding_schema_WebView");
const webcore_cookies = @import("binding_schema_WebCoreCookies");
const yaml = @import("binding_schema_YAMLObject");

const read_only = b.SurfaceMemberOptions{
    .attributes = .{ .writable = false, .configurable = false },
};
const hidden = b.SurfaceMemberOptions{
    .attributes = .{ .enumerable = false, .configurable = false },
};
const hidden_read_only = b.SurfaceMemberOptions{
    .attributes = .{ .writable = false, .enumerable = false, .configurable = false },
};
const permanent = b.SurfaceMemberOptions{
    .attributes = .{ .configurable = false },
};
const configurable = b.SurfaceMemberOptions{ .attributes = .{} };
const constructable = b.SurfaceMemberOptions{ .attributes = .{}, .constructable = true };
const direct_read_only = b.SurfaceMemberOptions{
    .attributes = .{ .writable = false, .configurable = false },
};
const tag = b.SurfaceMemberOptions{
    .attributes = .{ .writable = false, .enumerable = false },
};

fn bunFunction(comptime name: []const u8) b.SurfaceMember {
    return b.surfaceFunction(name, bun_object.schema.function(name), .{});
}

fn bunLazy(comptime name: []const u8, comptime options: b.SurfaceMemberOptions) b.SurfaceMember {
    return b.surfaceLazyProperty(name, bun_object.schema.nativeExport("lazy" ++ name), options);
}

fn lazyClass(comptime name: []const u8, comptime class: b.BoundClass, comptime options: b.SurfaceMemberOptions) b.SurfaceMember {
    return b.surfaceLazyProperty(name, class, options);
}

fn cppLazy(
    comptime name: []const u8,
    comptime symbol: []const u8,
    comptime options: b.SurfaceMemberOptions,
) b.SurfaceMember {
    return b.surfaceLazyProperty(name, bun_object.schema.function(symbol), options);
}

pub const bun_object_surface = b.objectSurface("BunObject", .{
    cppLazy("$", "constructBunShell", .{}),
    lazyClass("Archive", archive.archive, .{}),
    lazyClass("ArrayBufferSink", js_sink.schema.class("ArrayBufferSink"), .{}),
    lazyClass("Cookie", webcore_cookies.cookie, read_only),
    lazyClass("CookieMap", webcore_cookies.cookie_map, read_only),
    lazyClass("CryptoHasher", crypto_hasher.schema.class("CryptoHasher"), .{}),
    b.surfaceObjectValue("FFI", ffi_object, .{}),
    lazyClass("FileSystemRouter", file_system_router.schema.class("FileSystemRouter"), .{}),
    lazyClass("Glob", glob.glob, .{}),
    lazyClass("Image", image.image, .{}),
    lazyClass("MD4", static_hashers.md4, .{}),
    lazyClass("MD5", static_hashers.md5, .{}),
    lazyClass("SHA1", static_hashers.sha1, .{}),
    lazyClass("SHA224", static_hashers.sha224, .{}),
    lazyClass("SHA256", static_hashers.sha256, .{}),
    lazyClass("SHA384", static_hashers.sha384, .{}),
    lazyClass("SHA512", static_hashers.sha512, .{}),
    lazyClass("SHA512_256", static_hashers.sha512_256, .{}),
    b.surfaceObjectValue("JSONC", jsonc_object, .{}),
    b.surfaceObjectValue("JSON5", json5_object, .{}),
    b.surfaceObjectValue("JSONL", jsonl_object, read_only),
    b.surfaceObjectValue("markdown", markdown_object, .{}),
    b.surfaceObjectValue("TOML", toml_object, .{}),
    b.surfaceObjectValue("YAML", yaml_object, .{}),
    lazyClass("Transpiler", transpiler.schema.class("Transpiler"), .{}),
    bunLazy("embeddedFiles", .{}),
    lazyClass("S3Client", s3_client.s3_client, .{}),
    bunLazy("s3", .{}),
    b.surfaceObjectValue("CSRF", csrf_object, .{}),
    bunFunction("allocUnsafe"),
    bunLazy("argv", .{}),
    bunFunction("build"),
    bunFunction("concatArrayBuffers"),
    bunFunction("connect"),
    b.surfaceCallableValue("cron", cron_job.schema.function("register"), cron_function, .{}),
    bunLazy("cwd", hidden),
    bunFunction("color"),
    bunFunction("deepEquals"),
    bunFunction("deepMatch"),
    bunFunction("deflateSync"),
    b.surfaceObjectValue("dns", dns_object, read_only),
    bunLazy("enableANSIColors", .{}),
    cppLazy("env", "constructEnvObject", read_only),
    bunFunction("escapeHTML"),
    b.surfaceCallableValue("fetch", bun_object.schema.function("fetch"), fetch_function, read_only),
    bunFunction("file"),
    bunFunction("fileURLToPath"),
    bunFunction("gc"),
    bunFunction("generateHeapSnapshot"),
    bunFunction("gunzipSync"),
    bunFunction("gzipSync"),
    b.surfaceCallableValue("hash", hash.schema.function("wyhash"), hash_function, .{}),
    bunFunction("indexOfLine"),
    bunFunction("inflateSync"),
    b.surfaceCallableValue("inspect", bun_object.schema.function("inspect"), inspect_function, .{}),
    cppLazy("isMainThread", "constructIsMainThread", read_only),
    b.surfaceFunction("jest", bun_object.schema.function("jest"), hidden),
    bunFunction("listen"),
    bunFunction("udpSocket"),
    b.surfaceFunctionAccessor(
        "main",
        bun_object.schema.function("mainGet"),
        bun_object.schema.function("mainSet"),
        .{},
    ),
    bunFunction("mmap"),
    bunFunction("nanoseconds"),
    bunFunction("openInEditor"),
    bunLazy("origin", hidden_read_only),
    cppLazy("version_with_sha", "constructBunVersionWithSha", hidden_read_only),
    b.surfaceObjectValue("password", password_object, .{}),
    bunFunction("pathToFileURL"),
    b.surfaceCallableValue("peek", surface_builtins.schema.function("peek"), peek_function, .{}),
    b.surfaceCallableValue("plugin", runtime.schema.function("jsFunctionBunPlugin"), plugin_function, read_only),
    bunFunction("randomUUIDv7"),
    bunFunction("randomUUIDv5"),
    bunFunction("readableStreamToArray"),
    bunFunction("readableStreamToArrayBuffer"),
    bunFunction("readableStreamToBytes"),
    bunFunction("readableStreamToBlob"),
    bunFunction("readableStreamToFormData"),
    bunFunction("readableStreamToJSON"),
    bunFunction("readableStreamToText"),
    bunFunction("resolve"),
    bunFunction("resolveSync"),
    cppLazy("revision", "constructBunRevision", read_only),
    b.surfaceObjectValue("semver", semver_object, read_only),
    cppLazy("sql", "defaultBunSQLObject", .{}),
    cppLazy("postgres", "defaultBunSQLObject", .{}),
    cppLazy("SQL", "constructBunSQLObject", .{}),
    bunFunction("serve"),
    bunFunction("sha"),
    bunFunction("shrink"),
    b.surfaceFunction("sliceAnsi", string_width.schema.function("sliceAnsi"), .{}),
    bunFunction("sleep"),
    bunFunction("sleepSync"),
    bunFunction("spawn"),
    bunFunction("spawnSync"),
    b.surfaceLazyProperty("stderr", bun_object.schema.function("bunStderr"), .{}),
    b.surfaceLazyProperty("stdin", bun_object.schema.function("bunStdin"), .{}),
    b.surfaceLazyProperty("stdout", bun_object.schema.function("bunStdout"), .{}),
    bunFunction("stringWidth"),
    bunFunction("stripANSI"),
    b.surfaceFunction("wrapAnsi", string_width.schema.function("wrapAnsi"), .{}),
    lazyClass("Terminal", terminal.terminal, .{}),
    b.surfaceObjectValue("unsafe", unsafe_surface, .{}),
    cppLazy("version", "constructBunVersion", read_only),
    lazyClass("WebView", web_view.web_view, read_only),
    bunFunction("which"),
    lazyClass("RedisClient", redis_client.redis_client, .{}),
    b.surfaceLazyProperty("redis", bun_object.schema.nativeExport("lazyvalkey"), .{ .native_accessor = "defaultRedisClient" }),
    b.surfaceObjectValue("secrets", secrets_object, .{}),
    bunFunction("write"),
    bunFunction("zstdCompressSync"),
    bunFunction("zstdDecompressSync"),
    bunFunction("zstdCompress"),
    bunFunction("zstdDecompress"),
}, .{});

const csrf_object = b.objectSurface("BunCSRFObject", .{
    b.surfaceFunction("generate", csrf.schema.function("generate"), configurable),
    b.surfaceFunction("verify", csrf.schema.function("verify"), configurable),
}, .{ .installation = .direct });

const dns_object = b.objectSurface("BunDNSObject", .{
    b.surfaceFunction("lookup", node_dns.schema.function("lookup"), permanent),
    b.surfaceFunction("resolve", node_dns.schema.function("resolve"), permanent),
    b.surfaceFunction("resolveSrv", node_dns.schema.function("resolveSrv"), permanent),
    b.surfaceFunction("resolveTxt", node_dns.schema.function("resolveTxt"), permanent),
    b.surfaceFunction("resolveSoa", node_dns.schema.function("resolveSoa"), permanent),
    b.surfaceFunction("resolveNaptr", node_dns.schema.function("resolveNaptr"), permanent),
    b.surfaceFunction("resolveMx", node_dns.schema.function("resolveMx"), permanent),
    b.surfaceFunction("resolveCaa", node_dns.schema.function("resolveCaa"), permanent),
    b.surfaceFunction("resolveNs", node_dns.schema.function("resolveNs"), permanent),
    b.surfaceFunction("resolvePtr", node_dns.schema.function("resolvePtr"), permanent),
    b.surfaceFunction("resolveCname", node_dns.schema.function("resolveCname"), permanent),
    b.surfaceFunction("resolveAny", node_dns.schema.function("resolveAny"), permanent),
    b.surfaceFunction("getServers", node_dns.schema.function("getServers"), permanent),
    b.surfaceFunction("setServers", node_dns.schema.function("setServers"), permanent),
    b.surfaceFunction("reverse", node_dns.schema.function("reverse"), permanent),
    b.surfaceFunction("lookupService", node_dns.schema.function("lookupService"), permanent),
    b.surfaceFunction("prefetch", node_dns.schema.function("prefetch"), permanent),
    b.surfaceFunction("getCacheStats", node_dns.schema.function("getCacheStats"), permanent),
    b.surfaceExternalNumber("ADDRCONFIG", "AI_ADDRCONFIG", permanent),
    b.surfaceExternalNumber("ALL", "AI_ALL", permanent),
    b.surfaceExternalNumber("V4MAPPED", "AI_V4MAPPED", permanent),
}, .{ .installation = .direct });

const password_object = b.objectSurface("BunPasswordObject", .{
    b.surfaceFunction("hash", password.schema.function("hash"), configurable),
    b.surfaceFunction("hashSync", password.schema.function("hashSync"), configurable),
    b.surfaceFunction("verify", password.schema.function("verify"), configurable),
    b.surfaceFunction("verifySync", password.schema.function("verifySync"), configurable),
}, .{ .installation = .direct });

const secrets_object = b.objectSurface("BunSecretsObject", .{
    b.surfaceFunction("get", secrets.schema.function("get"), read_only),
    b.surfaceFunction("set", secrets.schema.function("set"), read_only),
    b.surfaceFunction("delete", secrets.schema.function("delete"), read_only),
}, .{ .installation = .direct });

const cron_function = b.objectSurface("BunCronFunction", .{
    b.surfaceFunction("remove", cron_job.schema.function("remove"), configurable),
    b.surfaceFunction("parse", cron_job.schema.function("parse"), configurable),
}, .{ .installation = .direct });

const ffi_object = b.objectSurface("BunFFIObject", .{
    b.surfaceFunction("viewSourceSymbols", ffi.schema.function("viewSourceSymbols"), configurable),
    b.surfaceFunction("viewSourceCallback", ffi.schema.function("viewSourceCallback"), configurable),
    b.surfaceFunction("dlopen", ffi.schema.function("dlopen"), configurable),
    b.surfaceFunction("callback", ffi.schema.function("callback"), configurable),
    b.surfaceFunction("linkSymbols", ffi.schema.function("linkSymbols"), configurable),
    b.surfaceFunction("toBuffer", ffi.schema.function("toBuffer"), configurable),
    b.surfaceFunction("toArrayBuffer", ffi.schema.function("toArrayBuffer"), configurable),
    b.surfaceFunction("CString", ffi.schema.function("CString"), constructable),
    b.surfaceFunction("ptr", ffi.schema.function("ptr"), configurable),
    b.surfaceObjectValue("read", ffi_reader, configurable),
}, .{ .installation = .direct });

const ffi_reader = b.objectSurface("BunFFIReader", .{
    b.surfaceFunction("u8", ffi.schema.function("readerU8"), configurable),
    b.surfaceFunction("u16", ffi.schema.function("readerU16"), configurable),
    b.surfaceFunction("u32", ffi.schema.function("readerU32"), configurable),
    b.surfaceFunction("ptr", ffi.schema.function("readerPtr"), configurable),
    b.surfaceFunction("i8", ffi.schema.function("readerI8"), configurable),
    b.surfaceFunction("i16", ffi.schema.function("readerI16"), configurable),
    b.surfaceFunction("i32", ffi.schema.function("readerI32"), configurable),
    b.surfaceFunction("i64", ffi.schema.function("readerI64"), configurable),
    b.surfaceFunction("u64", ffi.schema.function("readerU64"), configurable),
    b.surfaceFunction("intptr", ffi.schema.function("readerIntptr"), configurable),
    b.surfaceFunction("f32", ffi.schema.function("readerF32"), configurable),
    b.surfaceFunction("f64", ffi.schema.function("readerF64"), configurable),
}, .{ .installation = .direct });

const jsonc_object = b.objectSurface("BunJSONCObject", .{
    b.surfaceFunction("parse", jsonc.schema.function("parse"), configurable),
}, .{ .installation = .direct });

const json5_object = b.objectSurface("BunJSON5Object", .{
    b.surfaceFunction("parse", json5.schema.function("parse"), configurable),
    b.surfaceFunction("stringify", json5.schema.function("stringify"), configurable),
}, .{ .installation = .direct });

const markdown_object = b.objectSurface("BunMarkdownObject", .{
    b.surfaceFunction("html", markdown.schema.function("html"), configurable),
    b.surfaceFunction("ansi", markdown.schema.function("ansi"), configurable),
    b.surfaceFunction("render", markdown.schema.function("render"), configurable),
    b.surfaceFunction("react", markdown.schema.function("react"), configurable),
}, .{ .installation = .direct });

const semver_object = b.objectSurface("BunSemverObject", .{
    b.surfaceFunction("satisfies", semver.schema.function("satisfies"), configurable),
    b.surfaceFunction("order", semver.schema.function("order"), configurable),
}, .{ .installation = .direct });

const toml_object = b.objectSurface("BunTOMLObject", .{
    b.surfaceFunction("parse", toml.schema.function("parse"), configurable),
    b.surfaceFunction("stringify", toml.schema.function("stringify"), configurable),
}, .{ .installation = .direct });

const unsafe_surface = b.objectSurface("BunUnsafeObject", .{
    b.surfaceFunction("gcAggressionLevel", unsafe_object.schema.function("gcAggressionLevel"), configurable),
    b.surfaceFunction("arrayBufferToString", unsafe_object.schema.function("arrayBufferToString"), configurable),
    b.surfaceFunction("mimallocDump", unsafe_object.schema.function("mimallocDump"), configurable),
}, .{ .installation = .direct });

const yaml_object = b.objectSurface("BunYAMLObject", .{
    b.surfaceFunction("parse", yaml.schema.function("parse"), configurable),
    b.surfaceFunction("stringify", yaml.schema.function("stringify"), configurable),
}, .{ .installation = .direct });

const plugin_function = b.objectSurface("BunPluginFunction", .{
    b.surfaceFunction("clearAll", runtime.schema.function("jsFunctionBunPluginClear"), permanent),
}, .{ .installation = .direct });

pub const fetch_function = b.objectSurface("BunFetchFunction", .{
    b.surfaceFunction("preconnect", bun_object.schema.function("fetchPreconnect"), direct_read_only),
}, .{ .installation = .direct });

const shell_object = b.objectSurface("BunShellObject", .{
    b.surfaceFunction("braces", bun_object.schema.function("braces"), direct_read_only),
    b.surfaceFunction("escape", bun_object.schema.function("shellEscape"), direct_read_only),
}, .{ .installation = .direct });

const jsonl_object = b.objectSurface("BunJSONLObject", .{
    b.surfaceFunction("parse", bun_object.schema.function("jsonlParse"), permanent),
    b.surfaceFunction("parseChunk", bun_object.schema.function("jsonlParseChunk"), permanent),
    b.surfaceSymbolString(.to_string_tag, "JSONL", tag),
}, .{ .installation = .direct });

const peek_function = b.objectSurface("BunPeekFunction", .{
    b.surfaceFunction("status", surface_builtins.schema.function("peekStatus"), direct_read_only),
}, .{ .installation = .direct });

const hash_function = b.objectSurface("BunHashFunction", .{
    b.surfaceFunction("wyhash", hash.schema.function("wyhash"), .{}),
    b.surfaceFunction("adler32", hash.schema.function("adler32"), .{}),
    b.surfaceFunction("crc32", hash.schema.function("crc32"), .{}),
    b.surfaceFunction("cityHash32", hash.schema.function("cityHash32"), .{}),
    b.surfaceFunction("cityHash64", hash.schema.function("cityHash64"), .{}),
    b.surfaceFunction("xxHash32", hash.schema.function("xxHash32"), .{}),
    b.surfaceFunction("xxHash64", hash.schema.function("xxHash64"), .{}),
    b.surfaceFunction("xxHash3", hash.schema.function("xxHash3"), .{}),
    b.surfaceFunction("murmur32v2", hash.schema.function("murmur32v2"), .{}),
    b.surfaceFunction("murmur32v3", hash.schema.function("murmur32v3"), .{}),
    b.surfaceFunction("murmur64v2", hash.schema.function("murmur64v2"), .{}),
    b.surfaceFunction("rapidhash", hash.schema.function("rapidhash"), .{}),
}, .{ .installation = .direct });

const inspect_function = b.objectSurface("BunInspectFunction", .{
    b.surfaceRegisteredSymbol("custom", "nodejs.util.inspect.custom", configurable),
    b.surfaceFunction("table", bun_object.schema.function("inspectTable"), configurable),
}, .{ .installation = .direct });

const plugin_builder = b.objectSurface("BunPluginBuilder", .{
    b.surfaceString("target", "bun", configurable),
    b.surfaceFunction("onLoad", runtime.schema.function("jsFunctionAppendOnLoadPluginBun"), permanent),
    b.surfaceFunction("onResolve", runtime.schema.function("jsFunctionAppendOnResolvePluginBun"), permanent),
    b.surfaceFunction("module", runtime.schema.function("jsFunctionAppendVirtualModule"), permanent),
}, .{ .installation = .direct });

pub const schema = b.moduleWithSurfaces("BunObjectSurface", .{
    csrf_object,
    dns_object,
    password_object,
    secrets_object,
    cron_function,
    ffi_reader,
    ffi_object,
    jsonc_object,
    json5_object,
    markdown_object,
    semver_object,
    toml_object,
    unsafe_surface,
    yaml_object,
    plugin_function,
    fetch_function,
    shell_object,
    jsonl_object,
    peek_function,
    hash_function,
    inspect_function,
    plugin_builder,
    bun_object_surface,
});
