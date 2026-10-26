//! `Bun.Image` — Sharp-shaped image pipeline backed by the statically linked
//! libjpeg-turbo / libspng / libwebp codecs and the highway resize kernel.
//!
//! Shape: the constructor only captures the *input* (path or bytes). Chainable
//! mutators (`resize`, `rotate`, `flip`, `flop`, `jpeg`/`png`/`webp`) each
//! write one slot of `Pipeline` and return `this` — there is no op list, so
//! calling a setter twice overwrites. The actual decode → transform → encode
//! work happens off-thread when a terminal (`bytes`/`buffer`/`blob`/
//! `toBase64`/`metadata`) is awaited.

const Image = @This();

pub const JSBinding = struct {
    bindgen_state: bindgen.ClassState = .{},
    image: bindgen.OwnedNative(Image, .any),
    pending_input: ?bindgen.Root = null,

    pub fn construct(
        context: bindgen.CallContext(ImageConstructorSchema),
        args: bindgen.Args(ImageConstructorSchema),
    ) bindgen.CallError(ImageConstructorSchema)!*JSBinding {
        const options = if (args.options) |value| ConstructorOptions.fromBindgen(value) else ConstructorOptions{};
        const input_arg = args.input orelse return context.fail(.missing_input, {});
        const converted_input = try input_arg.convert(context);

        const binding = try bindingFromOwnedSource(try sourceFromBindgen(context, &converted_input.value), options);
        errdefer binding.destroy();
        if (converted_input.value == .buffer) {
            var input = try converted_input.value.buffer.toOwned();
            binding.pending_input = input.takeAnyRoot();
        }
        return binding;
    }

    pub const destroy = deinit;

    fn deinit(this: *JSBinding) void {
        if (this.pending_input) |*input| input.deinit();
        this.image.deinit();
        bun.destroy(this);
    }

    pub fn memoryUsage(this: *const JSBinding, _: bun.bindgen.MemoryUsageContext(.any)) usize {
        return @sizeOf(JSBinding) + this.image.get().estimatedSize();
    }

    pub fn takeInput(
        this: *JSBinding,
        context: bindgen.CallContext(ImageInputSchema),
        _: bindgen.Args(ImageInputSchema),
    ) bun.JSError!bindgen.Return(ImageInputSchema) {
        var root = this.pending_input orelse return .initUndefined(context);
        this.pending_input = null;
        return .fromOwnedRoot(&root, context);
    }

    pub fn bindResize(
        this: *JSBinding,
        _: bindgen.CallContext(ImageResizeSchema),
        args: bindgen.Args(ImageResizeSchema),
    ) bun.JSError!bindgen.Return(ImageResizeSchema) {
        var resize: Resize = .{
            .w = args.width,
            // Zero preserves the source aspect ratio once dimensions are known.
            .h = args.height orelse 0,
        };
        if (args.options) |options| {
            if (options.filter) |filter| resize.filter = switch (filter) {
                .box => .box,
                .bilinear => .bilinear,
                .lanczos3 => .lanczos3,
                .mitchell => .mitchell,
                .nearest => .nearest,
                .cubic => .cubic,
                .lanczos2 => .lanczos2,
                .mks2013 => .mks2013,
                .mks2021 => .mks2021,
            };
            if (options.fit) |fit| resize.fit = switch (fit) {
                .fill => .fill,
                .inside => .inside,
            };
            if (options.without_enlargement) |without_enlargement| {
                resize.without_enlargement = without_enlargement;
            }
        }
        this.image.get().pipeline.resize = resize;
        return args.bindingThis.toOwned();
    }

    pub fn bindRotate(
        this: *JSBinding,
        context: bindgen.CallContext(ImageRotateSchema),
        args: bindgen.Args(ImageRotateSchema),
    ) bindgen.CallError(ImageRotateSchema)!bindgen.Return(ImageRotateSchema) {
        const degrees: u32 = @intCast(@mod(args.degrees, 360));
        if (degrees != 0 and degrees != 90 and degrees != 180 and degrees != 270) {
            return context.fail(.invalid_degrees, {});
        }
        this.image.get().pipeline.rotate = @intCast(degrees);
        return args.bindingThis.toOwned();
    }

    pub fn bindFlip(
        this: *JSBinding,
        _: bindgen.CallContext(ImageFlipSchema),
        args: bindgen.Args(ImageFlipSchema),
    ) bun.JSError!bindgen.Return(ImageFlipSchema) {
        this.image.get().pipeline.flip = true;
        return args.bindingThis.toOwned();
    }

    pub fn bindFlop(
        this: *JSBinding,
        _: bindgen.CallContext(ImageFlopSchema),
        args: bindgen.Args(ImageFlopSchema),
    ) bun.JSError!bindgen.Return(ImageFlopSchema) {
        this.image.get().pipeline.flop = true;
        return args.bindingThis.toOwned();
    }

    pub fn bindModulate(
        this: *JSBinding,
        _: bindgen.CallContext(ImageModulateSchema),
        args: bindgen.Args(ImageModulateSchema),
    ) bun.JSError!bindgen.Return(ImageModulateSchema) {
        var modulate = this.image.get().pipeline.modulate orelse Modulate{};
        if (args.options) |options| {
            if (options.brightness) |brightness| {
                modulate.brightness = finiteModulation(brightness);
            }
            if (options.saturation) |saturation| {
                modulate.saturation = finiteModulation(saturation);
            }
        }
        this.image.get().pipeline.modulate = modulate;
        return args.bindingThis.toOwned();
    }

    pub const bindFormatJpeg = FormatMethod(ImageJpegSchema, .jpeg).call;
    pub const bindFormatPng = FormatMethod(ImagePngSchema, .png).call;
    pub const bindFormatWebp = FormatMethod(ImageWebpSchema, .webp).call;
    pub const bindFormatHeic = FormatMethod(ImageHeicSchema, .heic).call;
    pub const bindFormatAvif = FormatMethod(ImageAvifSchema, .avif).call;

    fn FormatMethod(comptime Schema: type, comptime format: codecs.Format) type {
        return struct {
            pub fn call(this: *JSBinding, _: bindgen.CallContext(Schema), args: bindgen.Args(Schema)) bun.JSError!bindgen.Return(Schema) {
                var encoded = this.image.get().pipeline.output orelse codecs.EncodeOptions{ .format = format };
                encoded.format = format;
                if (args.options) |values| {
                    if (values.quality) |quality| encoded.quality = quality;
                    if (values.lossless) |lossless| encoded.lossless = lossless;
                    if (values.compression_level) |compression_level| encoded.compression_level = @intCast(compression_level);
                    if (values.palette) |palette| encoded.palette = palette;
                    if (values.colors) |colors| encoded.colors = colors;
                    if (values.dither) |dither| encoded.dither = dither;
                    if (values.progressive) |progressive| encoded.progressive = progressive;
                }
                this.image.get().pipeline.output = encoded;
                return args.bindingThis.toOwned();
            }
        };
    }

    pub const bindMetadata = PipelineMethod(ImageMetadataSchema, .metadata).call;
    pub const bindBytes = PipelineMethod(ImageBytesSchema, .encode).call;
    pub const bindBuffer = PipelineMethod(ImageBufferSchema, .encode).call;
    pub const bindToBuffer = PipelineMethod(ImageToBufferSchema, .encode).call;
    pub const bindBlobNative = PipelineMethod(ImageBlobNativeSchema, .encode).call;
    pub const bindToBase64 = PipelineMethod(ImageToBase64Schema, .encode).call;
    pub const bindDataURL = PipelineMethod(ImageDataURLSchema, .encode).call;
    pub const bindPlaceholder = PipelineMethod(ImagePlaceholderSchema, .placeholder).call;

    fn PipelineMethod(comptime Schema: type, comptime kind: std.meta.Tag(PipelineKind)) type {
        return struct {
            pub fn call(this: *JSBinding, context: bindgen.CallContext(Schema), args: bindgen.Args(Schema)) bindgen.CallError(Schema)!void {
                return this.image.get().scheduleAsync(
                    Schema,
                    context,
                    try args.bindingThis.toOwned(),
                    args.source_buffer,
                    switch (kind) {
                        .encode => .{ .encode = this.image.get().pipeline.output },
                        .metadata => .metadata,
                        .placeholder => .placeholder,
                    },
                    null,
                );
            }
        };
    }

    pub fn bindWriteNative(
        this: *JSBinding,
        context: bindgen.CallContext(ImageWriteNativeSchema),
        args: bindgen.Args(ImageWriteNativeSchema),
    ) bindgen.CallError(ImageWriteNativeSchema)!void {
        const destination = args.destination orelse return context.fail(.missing_destination, {});
        var wrapper = try args.bindingThis.toOwned();
        defer wrapper.deinit();
        var owned_destination = try OwnedWriteDestination.fromBindgen(context, destination);
        return this.image.get().scheduleWrite(
            context,
            wrapper.take(),
            args.source_buffer,
            owned_destination.take(),
        );
    }

    pub fn bindGetWidth(
        this: *JSBinding,
        _: bindgen.CallContext(ImageWidthSchema),
        _: bindgen.Args(ImageWidthSchema),
    ) bun.JSError!i32 {
        return this.image.get().last_width;
    }

    pub fn bindGetHeight(
        this: *JSBinding,
        _: bindgen.CallContext(ImageHeightSchema),
        _: bindgen.Args(ImageHeightSchema),
    ) bun.JSError!i32 {
        return this.image.get().last_height;
    }

    pub fn bindGetBackend(
        _: bindgen.CallContext(ImageBackendGetterSchema),
        _: bindgen.Args(ImageBackendGetterSchema),
    ) bun.JSError!ImageBackend {
        return switch (codecs.getBackend()) {
            .system => .system,
            .bun => .bun,
        };
    }

    pub fn bindSetBackend(
        _: bindgen.CallContext(ImageBackendSetterSchema),
        args: bindgen.Args(ImageBackendSetterSchema),
    ) bun.JSError!void {
        codecs.setBackend(switch (args.value) {
            .system => .system,
            .bun => .bun,
        });
    }

    pub fn bindFromClipboard(
        context: bindgen.CallContext(ImageFromClipboardSchema),
        _: bindgen.Args(ImageFromClipboardSchema),
    ) bun.JSError!?bindgen.ClassRef(ImageClassSchema) {
        const binding = try Image.fromClipboard() orelse return null;
        return try ImageClass.adoptResult(binding, context);
    }

    pub fn bindHasClipboardImage(
        _: bindgen.CallContext(ImageHasClipboardImageSchema),
        _: bindgen.Args(ImageHasClipboardImageSchema),
    ) bun.JSError!bool {
        return if (comptime codecs.system_backend) |backend|
            backend.hasClipboardImage()
        else
            false;
    }

    pub fn bindClipboardChangeCount(
        _: bindgen.CallContext(ImageClipboardChangeCountSchema),
        _: bindgen.Args(ImageClipboardChangeCountSchema),
    ) bun.JSError!i64 {
        return if (comptime codecs.system_backend) |backend|
            backend.clipboardChangeCount()
        else
            -1;
    }
};

source: Source,
pipeline: Pipeline = .{},
/// Decompression-bomb guard. Checked against the *header* dimensions before
/// any RGBA buffer is allocated. Mirrors Sharp's `limitInputPixels`.
max_pixels: u64 = codecs.default_max_pixels,
/// Apply EXIF Orientation (JPEG) before any user ops, the way Sharp's
/// `.rotate()`-with-no-args / `autoOrient` does.
auto_orient: bool = true,
/// Populated after a pipeline has run once; lets `.width`/`.height` answer
/// synchronously after the first await.
last_width: i32 = -1,
last_height: i32 = -1,

pub const Source = union(enum) {
    buffer,
    owned: bindgen.OwnedBytes,
    path: bindgen.OwnedBytes,
    blob: bun.webcore.Blob,

    fn deinit(self: *Source) void {
        switch (self.*) {
            .buffer => {},
            .owned, .path => |*bytes| bytes.deinit(),
            .blob => |*blob| blob.deinit(),
        }
    }
};

pub const Fit = enum {
    fill,
    inside,
    pub const Map = bun.ComptimeEnumMap(Fit);
};

pub const Resize = struct {
    w: u32,
    h: u32,
    filter: codecs.Filter = .lanczos3,
    fit: Fit = .fill,
    without_enlargement: bool = false,
};

/// One slot per operation, not an op list — calling `.resize()` twice
/// overwrites, it doesn't resize twice. This is Sharp's semantics and means
/// the worker snapshot is a plain struct copy with a fixed execution order
/// (`run()` below), no allocation, no "too many ops" edge.
///
/// Execution order matches Sharp: (autoOrient) → rotate → flip/flop → resize
/// → modulate. Rotate precedes resize so the target box is interpreted in
/// upright space; modulate runs last so it operates on the fewest pixels.
pub const Pipeline = struct {
    rotate: u16 = 0, // 0/90/180/270
    flip: bool = false, // vertical
    flop: bool = false, // horizontal
    resize: ?Resize = null,
    modulate: ?Modulate = null,
    /// Output settings from `.jpeg()/.png()/.webp()`. `null` ⇒ re-encode in
    /// source format.
    output: ?codecs.EncodeOptions = null,
};

pub const Modulate = struct {
    /// Multiplier; 1.0 = identity.
    brightness: f32 = 1.0,
    /// 0 = greyscale, 1 = identity, >1 = boost.
    saturation: f32 = 1.0,
};

/// Size cap for `.path` sources, applied at fstat time before reading
/// anything. This is the *encoded* file, not the decoded RGBA — `maxPixels`
/// covers the latter once we have a header. 256 MiB comfortably fits any
/// real-world image (a 268 MP JPEG is ~80 MB) while keeping a single
/// path-driven request from materialising gigabytes before any guard runs.
const max_input_file_bytes: u64 = 256 << 20;

// ───────────────────────────── lifecycle ────────────────────────────────────

/// `Bun.file("…").image()` / `Bun.s3("…").image()` / `Blob#image()`. Same
/// allocation as `new Bun.Image(blob, opts)`.
pub const ConstructorOptions = struct {
    max_pixels: ?u64 = null,
    auto_orient: ?bool = null,

    pub fn fromBindgen(options: anytype) ConstructorOptions {
        return .{
            .max_pixels = options.max_pixels,
            .auto_orient = options.auto_orient,
        };
    }
};

fn bindingFromBlob(blob: *const bun.webcore.Blob, options: ConstructorOptions) bun.OOM!*JSBinding {
    return bindingFromOwnedSource(.{ .blob = try blob.dupe() }, options);
}

fn bindingFromOwnedSource(source: Source, options: ConstructorOptions) bun.OOM!*JSBinding {
    const image = image: {
        var owned_source = source;
        errdefer owned_source.deinit();
        const value = try bun.default_allocator.create(Image);
        value.* = .{ .source = owned_source };
        break :image value;
    };
    errdefer image.destroy();
    applyOptions(image, options);
    const binding = try bun.default_allocator.create(JSBinding);
    binding.* = .{ .image = .init(image) };
    return binding;
}

pub fn fromBlobResult(context: anytype, blob: *const bun.webcore.Blob, options: ConstructorOptions) bun.JSError!bindgen.ClassRef(ImageClassSchema) {
    const binding = try bindingFromBlob(blob, options);
    return ImageClass.adoptResult(binding, context);
}

fn applyOptions(img: *Image, options: ConstructorOptions) void {
    if (options.max_pixels) |max_pixels| img.max_pixels = max_pixels;
    if (options.auto_orient) |auto_orient| img.auto_orient = auto_orient;
}

pub fn finalize(this: *Image) void {
    this.source.deinit();
    bun.destroy(this);
}

pub fn destroy(this: *Image) void {
    this.finalize();
}

pub fn estimatedSize(this: *const Image) usize {
    return @sizeOf(Image) + switch (this.source) {
        .blob, .buffer => 0,
        .owned, .path => |*bytes| bytes.length(),
    };
}

fn sourceFromBindgen(
    context: bindgen.CallContext(ImageConstructorSchema),
    input: anytype,
) bindgen.CallError(ImageConstructorSchema)!Source {
    return switch (input.*) {
        .blob => |*blob_ref| .{ .blob = try blob_ref.get().dupe() },
        .buffer => .buffer,
        .string => |*string| source: {
            const utf8 = try string.toUTF8(bun.default_allocator);
            defer utf8.deinit();
            const value = utf8.slice();
            if (!bun.strings.hasPrefixComptime(value, "data:")) {
                break :source .{ .path = try .fromSlice(value) };
            }

            const comma = bun.strings.indexOfChar(value, ',') orelse
                return context.fail(.malformed_data_url, {});
            const metadata = value[5..comma];
            if (!bun.strings.contains(metadata, ";base64")) {
                return context.fail(.unsupported_data_url, {});
            }
            const decoded = bun.base64.decodeAllocForgiving(bun.default_allocator, value[comma + 1 ..]) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.DecodingFailed => return context.fail(.invalid_base64, {}),
            };
            break :source .{ .owned = .fromDefaultAllocatedSlice(decoded) };
        },
    };
}

// ───────────────────────────── chainable ops ────────────────────────────────

fn finiteModulation(value: f64) f32 {
    return if (std.math.isFinite(value)) @floatCast(@min(@max(value, 0.0), 1e4)) else 1.0;
}

fn errorMessage(e: codecs.Error) [:0]const u8 {
    return switch (e) {
        error.UnknownFormat => "Image: unrecognised format (expected JPEG, PNG, WebP, GIF, BMP, TIFF, HEIC or AVIF)",
        error.DecodeFailed => "Image: decode failed",
        error.EncodeFailed => "Image: encode failed",
        error.InvalidDimensions => "Image: dimensions exceed the supported range",
        error.TooManyPixels => "Image: input exceeds maxPixels limit",
        error.UnsupportedOnPlatform => "Image: format not supported on this machine (HEIC/AVIF/TIFF require the OS codec; AVIF encode needs an AV1 encoder)",
        error.ConcurrencyUnavailable => "Image: background concurrency unavailable",
        error.OutOfMemory => "Image: out of memory",
    };
}

pub fn initialMetadataResult(this: *Image, input: ?[]const u8) ?PipelineResult {
    const bytes = input orelse this.jsThreadBytes() orelse return null;
    const probe = codecs.probe(bytes, this.max_pixels) catch |err| return switch (err) {
        error.UnsupportedOnPlatform => null,
        else => .{ .err = err },
    };
    var width = probe.width;
    var height = probe.height;
    if (this.auto_orient and probe.format == .jpeg) {
        const transform = exif.readJpeg(bytes).transform();
        if (transform.rotate == 90 or transform.rotate == 270) std.mem.swap(u32, &width, &height);
    }
    return .{ .meta = .{ .w = width, .h = height, .format = probe.format } };
}

fn jsThreadBytes(this: *Image) ?[]const u8 {
    return switch (this.source) {
        .owned => |*bytes| bytes.slice(),
        .path, .blob, .buffer => null,
    };
}

pub fn copyInputForTask(this: *Image, input: ?[]const u8) error{OutOfMemory}!OwnedPipelineInput {
    switch (this.source) {
        .buffer => {
            const bytes = input orelse @panic("Image buffer source has no declared input bytes");
            return .{ .bytes = try bun.default_allocator.dupe(u8, bytes) };
        },
        .owned => |*bytes| return .{ .bytes = try bun.default_allocator.dupe(u8, bytes.slice()) },
        .path => |*path| return .{ .path = try bun.default_allocator.dupeSentinel(u8, path.slice(), 0) },
        .blob => unreachable,
    }
}

fn inputForCurrentThread(this: *Image, snapshot: ?[]const u8) PipelineInput {
    return switch (this.source) {
        .buffer => .{ .bytes = snapshot orelse @panic("Image body encoding requires a source snapshot") },
        .owned => |*bytes| .{ .bytes = bytes.slice() },
        .path => |*path| .{ .path = path.slice() },
        .blob => unreachable,
    };
}

// ───────────── static `Bun.Image.fromClipboard()` / `.hasClipboardImage()` ──
//
// JS-thread synchronous read of the system clipboard for an image
// representation, returning a fresh `Bun.Image` wrapping the raw container
// bytes. Decode/encode still go through the normal off-thread pipeline; only
// the pasteboard fetch is synchronous, and that's a memcpy of bytes the OS
// already has in-process. `null` ⇔ no image present. Linux returns `null`
// unconditionally — there's no stable native API to dlopen and shelling out
// to `wl-paste`/`xclip` from inside `Bun.Image` is the wrong layer.

pub fn fromClipboard() bun.OOM!?*JSBinding {
    if (comptime codecs.system_backend) |sb| {
        const bytes = sb.clipboard() catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BackendUnavailable => return null,
        } orelse return null;
        return try bindingFromOwnedSource(.{ .owned = .fromDefaultAllocatedSlice(bytes) }, .{});
    }
    return null;
}

// ───────────────────────────── async terminals ──────────────────────────────

fn scheduleWrite(
    this: *Image,
    context: bindgen.CallContext(ImageWriteNativeSchema),
    wrapper: bindgen.ClassRef(ImageClassSchema),
    input: SourceBufferInput,
    destination: OwnedWriteDestination,
) bindgen.CallError(ImageWriteNativeSchema)!void {
    var output = this.pipeline.output;
    if (output == null) {
        if (destination.pathSlice()) |path| if (codecs.Format.fromExtension(path)) |f| switch (f) {
            .jpeg, .png, .webp, .heic, .avif => output = .{ .format = f },
            else => {},
        };
    }
    return this.scheduleAsync(
        ImageWriteNativeSchema,
        context,
        wrapper,
        input,
        .{ .encode = output },
        destination,
    );
}

fn scheduleAsync(
    this: *Image,
    comptime FunctionSchema: type,
    context: bindgen.CallContext(FunctionSchema),
    wrapper: bindgen.ClassRef(ImageClassSchema),
    input: SourceBufferInput,
    kind: PipelineKind,
    destination: ?OwnedWriteDestination,
) bindgen.CallError(FunctionSchema)!void {
    return bun.api.ImageEngine.schedule(this, FunctionSchema, context, wrapper, input, kind, destination);
}

/// Run the full pipeline on the *current* thread. Used when an `Image` is
/// passed straight to `new Response(image)` / `new Request(url, {body: image})`
/// — the body-init contract is synchronous, so we encode here and hand back an
/// owned buffer the Body can wrap as an `InternalBlob`. The async terminals
/// (`bytes`/`blob`/…) remain the off-thread path.
///
/// A later refinement is to return a `.Locked` body and resolve it from the
/// worker pool; this is the simple, correct first cut.
pub const BodyEncodeResult = union(enum) {
    encoded: struct { bytes: codecs.Encoded, mime: [:0]const u8 },
    unsupported_source,
    pipeline_error: [:0]const u8,
    io_error: bun.sys.Error,
};

pub fn encodeForBody(this: *Image, snapshot: ?[]const u8) bun.OOM!BodyEncodeResult {
    if (this.source == .blob) {
        const blob = &this.source.blob;
        const source: Source = if (blob.storePtr()) |store| switch (store.data) {
            .bytes => .{ .owned = try .fromSlice(blob.sharedView()) },
            .file => if (store.data.file.pathlike == .path)
                .{ .path = try .fromSlice(store.data.file.pathlike.path.slice()) }
            else
                return .unsupported_source,
            .s3 => return .unsupported_source,
        } else .{ .owned = .empty() };
        this.source.deinit();
        this.source = source;
    }
    const input = this.inputForCurrentThread(snapshot);
    var job: PipelineJob = .{
        .pipeline = this.pipeline,
        .input = input,
        .kind = .{ .encode = this.pipeline.output },
        .max_pixels = this.max_pixels,
        .auto_orient = this.auto_orient,
    };
    defer job.deinitResult();
    job.run();
    return switch (job.result) {
        .encoded => |e| {
            this.last_width = @intCast(e.w);
            this.last_height = @intCast(e.h);
            job.result = .{ .err = error.DecodeFailed };
            return .{ .encoded = .{ .bytes = e.out, .mime = e.format.mime() } };
        },
        .err => |e| .{ .pipeline_error = errorMessage(e) },
        .io_err => |e| .{ .io_error = e },
        .meta, .system_err => unreachable,
    };
}

// ───────────────────────────── worker task ──────────────────────────────────

const PipelineInput = union(enum) {
    none,
    bytes: []const u8,
    path: []const u8,
};

pub const OwnedPipelineInput = union(enum) {
    none,
    bytes: []u8,
    path: [:0]u8,

    fn view(this: *const OwnedPipelineInput) PipelineInput {
        return switch (this.*) {
            .none => .none,
            .bytes => |bytes| .{ .bytes = bytes },
            .path => |path| .{ .path = path },
        };
    }

    fn takeBytes(this: *OwnedPipelineInput) []u8 {
        const bytes = this.bytes;
        this.* = .none;
        return bytes;
    }

    fn deinit(this: *OwnedPipelineInput) void {
        switch (this.*) {
            .none => {},
            .bytes => |bytes| bun.default_allocator.free(bytes),
            .path => |path| bun.default_allocator.free(path),
        }
        this.* = .none;
    }
};

const ImageWriteDestination = @FieldType(bindgen.Return(ImageWriteNativeSchema), "destination");

pub const OwnedWriteDestination = struct {
    value: ?ImageWriteDestination,

    fn fromBindgen(context: anytype, value: anytype) bun.JSError!OwnedWriteDestination {
        return switch (value) {
            .path => |path| .{ .value = .{ .path = try path.copy() } },
            .fd => |fd| .{ .value = .{ .fd = fd } },
            .blob => |blob| result: {
                var copy = try blob.get().dupe();
                defer copy.deinit();
                break :result .{ .value = .{ .blob = try (try bun.webcore.Blob.new(&copy)).toBindingRef(context) } };
            },
        };
    }

    fn pathSlice(this: *const OwnedWriteDestination) ?[]const u8 {
        if (this.value) |*value| return switch (value.*) {
            .path => |*path| path.slice(),
            .fd, .blob => null,
        };
        return null;
    }

    pub fn take(this: *OwnedWriteDestination) OwnedWriteDestination {
        const value = this.value orelse @panic("image write destination was already consumed");
        this.value = null;
        return .{ .value = value };
    }

    fn takeResult(this: *OwnedWriteDestination) ImageWriteDestination {
        const result = this.value orelse @panic("image write destination was already consumed");
        this.value = null;
        return result;
    }

    pub fn deinit(this: *OwnedWriteDestination) void {
        var value = this.value orelse return;
        this.value = null;
        switch (value) {
            .path => |*path| path.deinit(),
            .blob => |*blob| blob.deinit(),
            .fd => {},
        }
    }
};

pub const PipelineKind = union(enum) {
    encode: ?codecs.EncodeOptions,
    metadata,
    placeholder,
};

pub const PipelineResult = union(enum) {
    encoded: struct { out: codecs.Encoded, format: codecs.Format, w: u32, h: u32 },
    meta: struct { w: u32, h: u32, format: codecs.Format },
    err: codecs.Error,
    io_err: bun.sys.Error,
    system_err: bindgen.SystemError,
};

const PipelineAttachment = struct {
    wrapper: bindgen.ClassRef(ImageClassSchema),
    destination: ?OwnedWriteDestination,
    cache_blob_source: bool,
    input_lease: ?bindgen.OwnedLease(u8) = null,

    fn deinit(this: *PipelineAttachment) void {
        if (this.destination) |*destination| destination.deinit();
        this.destination = null;
        if (this.input_lease) |*lease| lease.deinit();
        this.input_lease = null;
        this.wrapper.deinit();
    }
};

const PipelineJob = struct {
    pipeline: Pipeline,
    input: PipelineInput,
    kind: PipelineKind,
    max_pixels: u64,
    auto_orient: bool,
    result: PipelineResult = .{ .err = error.DecodeFailed },

    pub fn run(this: *PipelineJob) void {
        var owned_file: ?[]u8 = null;
        defer if (owned_file) |f| bun.default_allocator.free(f);
        const input: []const u8 = switch (this.input) {
            .none => unreachable,
            .bytes => |bytes| bytes,
            .path => |p| blk: {
                // The path string came straight from the constructor, so treat
                // it as untrusted: open + fstat first instead of `readFrom`.
                //   • !S_ISREG → ENODEV. `/dev/zero`/`/dev/urandom` would
                //     otherwise pread forever (st_size=0, never returns 0) until
                //     the doubling ArrayList OOMs the process; a FIFO with no
                //     writer would park this BackgroundWork thread in-kernel forever.
                //   • st_size cap → file-based decompression-bomb fails up
                //     front with a clear error instead of materialising a
                //     multi-GB encoded buffer before `maxPixels` even runs.
                // O_NONBLOCK so the open itself can't block on a FIFO. POSIX-only:
                // on Windows it omits FILE_SYNCHRONOUS_IO_NONALERT (overlapped
                // handle) and the subsequent sync read fails EINVAL. Windows has
                // no open-blocking FIFOs in the same sense; the !S_ISREG check
                // below still rejects pipes/devices.
                const oflags = bun.O.RDONLY | if (bun.Environment.isPosix) bun.O.NONBLOCK else @as(@TypeOf(bun.O.RDONLY), 0);
                const file = switch (bun.sys.openatA(bun.FD.cwd(), p, oflags, 0)) {
                    .result => |fd| bun.sys.File.from(fd),
                    .err => |e| {
                        this.result = .{ .io_err = e.withPath(p) };
                        return;
                    },
                };
                defer file.close();
                const st = switch (file.stat()) {
                    .result => |s| s,
                    .err => |e| {
                        this.result = .{ .io_err = e.withPath(p) };
                        return;
                    },
                };
                if (!bun.S.ISREG(@intCast(st.mode))) {
                    this.result = .{ .io_err = .{ .errno = @backingInt(bun.sys.E.NODEV), .syscall = .read, .path = p } };
                    return;
                }
                if (@as(u64, @intCast(@max(st.size, 0))) > max_input_file_bytes) {
                    this.result = .{ .err = error.TooManyPixels };
                    return;
                }
                const r = file.readToEnd(bun.default_allocator);
                if (r.err) |e| {
                    var bytes = r.bytes;
                    bytes.deinit();
                    this.result = .{ .io_err = e.withPath(p) };
                    return;
                }
                owned_file = r.bytes.items;
                break :blk owned_file.?;
            },
        };

        // Header-only fast path for `.metadata()` — Sharp parses just the
        // IHDR/SOF/VP8 header; we used to decode the full RGBA buffer first
        // (~70× slower on a 1920×1080 PNG). EXIF orientation only swaps the
        // reported dims, no pixels involved.
        if (this.kind == .metadata) {
            if (codecs.probe(input, this.max_pixels)) |p| {
                var w = p.width;
                var h = p.height;
                if (this.auto_orient and p.format == .jpeg) {
                    const t = exif.readJpeg(input).transform();
                    if (t.rotate == 90 or t.rotate == 270) std.mem.swap(u32, &w, &h);
                }
                this.result = .{ .meta = .{ .w = w, .h = h, .format = p.format } };
                return;
            } else |e| switch (e) {
                // HEIC/AVIF have no header probe — fall through to full decode
                // via the system backend.
                error.UnsupportedOnPlatform => {},
                else => {
                    this.result = .{ .err = e };
                    return;
                },
            }
        }

        // Decode-time downscale hint. The IDCT picker constrains in *stored*
        // axes, so any 90/270 rotate that runs before resize — explicit OR
        // EXIF auto-orient — needs the hint axes swapped, otherwise one axis
        // can be over-shrunk and then upscaled, throwing away detail.
        // (flip/flop are pure mirrors that never change w/h, so the hint
        //  stays valid through them.)
        const hint: codecs.DecodeHint = if (this.pipeline.resize) |r| blk: {
            var tw = r.w;
            // r.h==0 means "preserve aspect" — constrain on width only.
            var th = if (r.h != 0) r.h else r.w;
            const swap_explicit = this.pipeline.rotate == 90 or this.pipeline.rotate == 270;
            const swap_exif = this.auto_orient and blk2: {
                const t = exif.readJpeg(input).transform();
                break :blk2 t.rotate == 90 or t.rotate == 270;
            };
            if (swap_explicit != swap_exif) std.mem.swap(u32, &tw, &th);
            break :blk .{ .target_w = tw, .target_h = th };
        } else .{};

        var decoded = codecs.decode(input, this.max_pixels, hint) catch |e| {
            this.result = .{ .err = e };
            return;
        };
        defer decoded.deinit();

        const src_format = codecs.Format.sniff(input) orelse .png;

        // EXIF auto-orient: applied BEFORE any user op so resize targets and
        // metadata report the visually-upright dimensions, the way Sharp does.
        if (this.auto_orient and src_format == .jpeg) {
            const orient = exif.readJpeg(input);
            if (orient != .normal) applyOrientation(&decoded, orient) catch |e| {
                this.result = .{ .err = e };
                return;
            };
        }

        if (this.kind == .metadata) {
            // Reached only for HEIC/AVIF (probe fell through).
            this.result = .{ .meta = .{ .w = decoded.width, .h = decoded.height, .format = src_format } };
            return;
        }

        if (this.kind == .placeholder) {
            this.result = makePlaceholder(decoded.rgba, decoded.width, decoded.height) catch |e| .{ .err = e };
            return;
        }

        this.applyPipeline(&decoded) catch |e| {
            this.result = .{ .err = e };
            return;
        };

        // No format method chained ⇒ re-encode in the source format. For
        // decode-only sources (bmp/tiff/gif) that would dead-end in the
        // "HEIC/AVIF require macOS or Windows" message, which is wrong twice
        // over. Emit PNG instead — it's the lossless, everywhere-supported
        // default Sharp uses for the same case.
        var enc: codecs.EncodeOptions = this.kind.encode orelse .{
            .format = switch (src_format) {
                .bmp, .tiff, .gif => .png,
                else => src_format,
            },
        };
        // Carry the source ICC profile through to the encoder unless the
        // caller already set one (reserved for a future `.withIccProfile()`
        // method). The pipeline doesn't colour-convert the RGBA, so dropping
        // the profile reinterprets a non-sRGB source (Display-P3, Adobe RGB,
        // Jpegli XYB) as sRGB and visibly shifts the colours — see #30197.
        // JPEG/PNG/WebP embed it; HEIC/AVIF via the system backend do not.
        if (enc.icc_profile == null) enc.icc_profile = decoded.icc_profile;
        const out = codecs.encode(decoded.rgba, decoded.width, decoded.height, enc) catch |e| {
            this.result = .{ .err = e };
            return;
        };

        this.result = .{ .encoded = .{ .out = out, .format = enc.format, .w = decoded.width, .h = decoded.height } };
    }

    /// `.placeholder()` body — runs on the worker. Input is the decoded RGBA
    /// at source size; output is a PNG of the ThumbHash render, ready for the
    /// `.dataurl` deliver. ThumbHash needs ≤100×100, so first downscale with
    /// `box` (the only filter that's correct for "average everything in a
    /// cell" — Lanczos would ring into the DCT). The hash itself stays on
    /// the worker stack; only the rendered PNG crosses back.
    fn makePlaceholder(rgba: []const u8, sw: u32, sh: u32) codecs.Error!PipelineResult {
        const max_in: u32 = 100;
        var w = sw;
        var h = sh;
        var owned: ?[]u8 = null;
        defer if (owned) |o| bun.default_allocator.free(o);
        var pixels = rgba;
        if (w > max_in or h > max_in) {
            const r = @as(f32, @floatFromInt(w)) / @as(f32, @floatFromInt(h));
            if (r > 1) {
                w = max_in;
                h = @max(1, @as(u32, @intFromFloat(@round(max_in / r))));
            } else {
                h = max_in;
                w = @max(1, @as(u32, @intFromFloat(@round(max_in * r))));
            }
            owned = try codecs.resize(rgba, sw, sh, w, h, .box);
            pixels = owned.?;
        }
        var buf: [thumbhash.max_len]u8 = undefined;
        const hash = thumbhash.encode(&buf, w, h, pixels);
        const rendered = try thumbhash.decode(hash);
        defer bun.default_allocator.free(rendered.rgba);
        // Placeholder is a synthetic ThumbHash render, not the source image —
        // no ICC profile attaches to it.
        const png_out = try codecs.png.encode(rendered.rgba, rendered.w, rendered.h, -1, null);
        return .{ .encoded = .{ .out = png_out, .format = .png, .w = rendered.w, .h = rendered.h } };
    }

    /// Fixed Sharp order: rotate → flip/flop → resize. Each stage replaces
    /// `d` in place; the old buffer is freed before assigning the new one so
    /// peak memory is at most 2× one frame. Every stage hand-swaps only the
    /// pixel slots — rotate/resize return a fresh `Decoded` with
    /// `icc_profile == null`, so overwriting `d.*` wholesale would drop the
    /// source's colour profile. Geometry doesn't change colour meaning, so
    /// the profile survives unchanged.
    fn applyPipeline(this: *PipelineJob, d: *codecs.Decoded) codecs.Error!void {
        const p = this.pipeline;
        if (p.rotate != 0) {
            const next = try codecs.rotate(d.rgba, d.width, d.height, p.rotate);
            bun.default_allocator.free(d.rgba);
            d.rgba = next.rgba;
            d.width = next.width;
            d.height = next.height;
        }
        if (p.flip) {
            const next = try codecs.flip(d.rgba, d.width, d.height, false);
            bun.default_allocator.free(d.rgba);
            d.rgba = next;
        }
        if (p.flop) {
            const next = try codecs.flip(d.rgba, d.width, d.height, true);
            bun.default_allocator.free(d.rgba);
            d.rgba = next;
        }
        if (p.resize) |r| {
            const t = resolveResize(r, d.width, d.height);
            // Guard the output canvas AND the H-then-V intermediate (always
            // dst_w × src_h). A 1×N
            // source → resize(W,1) has tiny input AND output canvases yet a
            // W×N intermediate; with W=262143, N=16383 that's a 17 GiB alloc
            // from a ~200-byte PNG. The src_w×dst_h cross-product is bounded
            // by max(input, output) so doesn't need its own check.
            if (@as(u64, t.w) * t.h > this.max_pixels or
                @as(u64, t.w) * d.height > this.max_pixels)
                return error.TooManyPixels;
            if (t.w != d.width or t.h != d.height) {
                const next = try codecs.resize(d.rgba, d.width, d.height, t.w, t.h, r.filter);
                bun.default_allocator.free(d.rgba);
                d.rgba = next;
                d.width = t.w;
                d.height = t.h;
            }
        }
        if (p.modulate) |m| codecs.modulate(d.rgba, m.brightness, m.saturation);
    }

    /// Map a resize spec to concrete output dims given the current dims.
    fn resolveResize(r: Resize, sw: u32, sh: u32) struct { w: u32, h: u32 } {
        var w = r.w;
        // Widen before multiplying — `r.w` is user-controlled and `sh` is
        // bounded only by `max_pixels`, so the u32 product can wrap; and the
        // quotient can exceed u32 for tall-thin sources (1×5M with .resize(1k)
        // → 5e9), so clamp to the same per-side cap doResize uses before the
        // @intCast. The maxPixels guard then rejects the product.
        var h: u32 = if (r.h != 0) r.h else @intCast(@min(@as(u64, 0x3FFFF), @max(1, @as(u64, r.w) * sh / sw)));
        if (r.fit == .inside) {
            // Shrink the box so the source's aspect ratio is preserved and
            // both sides fit. (Sharp's `fit:'inside'`.)
            const sx = @as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(sw));
            const sy = @as(f64, @floatFromInt(h)) / @as(f64, @floatFromInt(sh));
            const s = @min(sx, sy);
            w = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(sw)) * s))));
            h = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(sh)) * s))));
        }
        if (r.without_enlargement and (w > sw or h > sh)) return .{ .w = sw, .h = sh };
        return .{ .w = w, .h = h };
    }

    fn applyOrientation(d: *codecs.Decoded, orient: exif.Orientation) codecs.Error!void {
        const t = orient.transform();
        if (t.flip) {
            const next = try codecs.flip(d.rgba, d.width, d.height, false);
            bun.default_allocator.free(d.rgba);
            d.rgba = next;
        }
        if (t.flop) {
            const next = try codecs.flip(d.rgba, d.width, d.height, true);
            bun.default_allocator.free(d.rgba);
            d.rgba = next;
        }
        if (t.rotate != 0) {
            // Swap pixel slots only — `next` carries no ICC profile, and the
            // one on `d` (set by decode) must survive EXIF auto-orient.
            const next = try codecs.rotate(d.rgba, d.width, d.height, t.rotate);
            bun.default_allocator.free(d.rgba);
            d.rgba = next.rgba;
            d.width = next.width;
            d.height = next.height;
        }
    }

    fn deinitResult(this: *PipelineJob) void {
        switch (this.result) {
            .encoded => |encoded| encoded.out.deinit(),
            .system_err => |*system_error| system_error.deinit(),
            else => {},
        }
        this.result = .{ .err = error.DecodeFailed };
    }
};

fn materializePipeline(
    comptime FunctionSchema: type,
    context: bindgen.MaterializationContext(FunctionSchema),
    attachment: *PipelineAttachment,
    input: *OwnedPipelineInput,
    job: *PipelineJob,
) bindgen.CallError(FunctionSchema)!bindgen.Return(FunctionSchema) {
    const image = attachment.wrapper.get(JSBinding).image.get();
    if (attachment.cache_blob_source and input.* == .bytes and image.source == .blob) {
        image.source.deinit();
        image.source = .{ .owned = .fromDefaultAllocatedSlice(input.takeBytes()) };
    }

    switch (job.result) {
        inline .encoded, .meta => |result| {
            image.last_width = @intCast(result.w);
            image.last_height = @intCast(result.h);
        },
        else => {},
    }

    return switch (job.result) {
        .encoded => |encoded_result| {
            if (comptime FunctionSchema == ImageBytesSchema or
                FunctionSchema == ImageBufferSchema or
                FunctionSchema == ImageToBufferSchema)
            {
                return try bindgen.OwnedBytes.fromSlice(encoded_result.out.bytes);
            }
            if (comptime FunctionSchema == ImageBlobNativeSchema) {
                var data = try bindgen.OwnedBytes.fromSlice(encoded_result.out.bytes);
                errdefer data.deinit();
                return .{
                    .data = data,
                    .mime = try bindgen.UTF8String.fromSlice(encoded_result.format.mime()),
                };
            }
            if (comptime FunctionSchema == ImageToBase64Schema) {
                return try encodedStringResult(encoded_result, false);
            }
            if (comptime FunctionSchema == ImageDataURLSchema or FunctionSchema == ImagePlaceholderSchema) {
                return try encodedStringResult(encoded_result, true);
            }
            if (comptime FunctionSchema == ImageWriteNativeSchema) {
                var data = try bindgen.OwnedBytes.fromSlice(encoded_result.out.bytes);
                errdefer data.deinit();
                const destination = if (attachment.destination) |*value|
                    value
                else
                    @panic("image write completion has no destination");
                return .{
                    .data = data,
                    .destination = destination.takeResult(),
                };
            }
            @panic("image pipeline produced encoded data for an incompatible endpoint");
        },
        .meta => |metadata| {
            if (comptime FunctionSchema != ImageMetadataSchema) {
                @panic("image pipeline produced metadata for an incompatible endpoint");
            }
            return .{
                .width = metadata.w,
                .height = metadata.h,
                .format = try bindgen.UTF8String.fromSlice(@tagName(metadata.format)),
            };
        },
        .err => |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.UnknownFormat => context.fail(.unknown_format, {}),
            error.DecodeFailed => context.fail(.decode_failed, {}),
            error.EncodeFailed => context.fail(.encode_failed, {}),
            error.InvalidDimensions => context.fail(.invalid_dimensions, {}),
            error.TooManyPixels => context.fail(.too_many_pixels, {}),
            error.UnsupportedOnPlatform => context.fail(.unsupported_on_platform, {}),
            error.ConcurrencyUnavailable => context.fail(.concurrency_unavailable, {}),
        },
        .io_err => |err| context.fail(.system, try bindgen.SystemError.fromSysError(err)),
        .system_err => |system_error_value| {
            job.result = .{ .err = error.DecodeFailed };
            return context.fail(.system, system_error_value);
        },
    };
}

fn encodedStringResult(
    encoded: @FieldType(PipelineResult, "encoded"),
    data_url: bool,
) bun.OOM!bindgen.UTF8String {
    var prefix_buffer: [40]u8 = undefined;
    const prefix: []const u8 = if (data_url)
        std.fmt.bufPrint(&prefix_buffer, "data:{s};base64,", .{encoded.format.mime()}) catch unreachable
    else
        "";
    const buffer = try bun.default_allocator.alloc(u8, prefix.len + bun.base64.encodeLen(encoded.out.bytes));
    defer bun.default_allocator.free(buffer);
    @memcpy(buffer[0..prefix.len], prefix);
    const written = prefix.len + bun.base64.encode(buffer[prefix.len..], encoded.out.bytes);
    return bindgen.UTF8String.fromSlice(buffer[0..written]);
}

pub fn AsyncPipeline(comptime FunctionSchema: type) type {
    return struct {
        const Self = @This();

        task: bun.BackgroundTaskGroup.Task = .{
            .callback = &runInBackground,
            .on_cancel = &cancel,
        },
        completion: Completion.Owned,
        input: OwnedPipelineInput,
        job: PipelineJob,

        const CompletionOps = struct {
            pub fn materialize(
                comptime Schema: type,
                context: bindgen.MaterializationContext(Schema),
                attachment: *PipelineAttachment,
                self: *Self,
            ) bindgen.CallError(Schema)!bindgen.Return(Schema) {
                return materializePipeline(Schema, context, attachment, &self.input, &self.job);
            }

            pub const destroyPayload = Self.deinit;

            pub fn destroyAttachment(attachment: *PipelineAttachment) void {
                attachment.deinit();
            }
        };

        const Completion = bindgen.MaterializedCompletion(
            FunctionSchema,
            Self,
            PipelineAttachment,
            CompletionOps,
        );

        pub const BlobReadChain = struct {
            owner: *Self,
            background_tasks: *bun.BackgroundTaskGroup,

            pub fn onReadBytes(chain: *@This(), result: bun.webcore.Blob.ReadBytesResult) void {
                const owner = chain.owner;
                const background_tasks = chain.background_tasks;
                bun.destroy(chain);
                switch (result) {
                    .ok => |bytes| {
                        owner.input = .{ .bytes = bytes };
                        owner.job.input = owner.input.view();
                        owner.schedule(background_tasks);
                    },
                    .err => |err| {
                        owner.job.result = .{ .system_err = err };
                        owner.completion.complete(owner);
                    },
                    .out_of_memory => {
                        owner.job.result = .{ .err = error.OutOfMemory };
                        owner.completion.complete(owner);
                    },
                    .cancelled => {
                        owner.completion.release();
                        owner.deinit();
                    },
                }
            }
        };

        pub fn start(
            image: *Image,
            background_tasks: *bun.BackgroundTaskGroup,
            context: bindgen.CallContext(FunctionSchema),
            wrapper: bindgen.ClassRef(ImageClassSchema),
            input_value: OwnedPipelineInput,
            lease_value: ?bindgen.OwnedLease(u8),
            kind: PipelineKind,
            destination_value: ?OwnedWriteDestination,
            initial_result: ?PipelineResult,
            cache_blob_source: bool,
        ) bindgen.CallError(FunctionSchema)!void {
            var input = input_value;
            var lease = lease_value;
            var wrapper_owner = wrapper;
            var destination = destination_value;
            const self = bun.default_allocator.create(Self) catch {
                input.deinit();
                if (lease) |*value| value.deinit();
                wrapper_owner.deinit();
                if (destination) |*value| value.deinit();
                return error.OutOfMemory;
            };

            var completion_view = context.completion();
            const completion = Completion.take(&completion_view, .{
                .wrapper = wrapper_owner.take(),
                .destination = if (destination) |*value| value.take() else null,
                .cache_blob_source = cache_blob_source,
                .input_lease = if (lease) |*value| value.take() else null,
            }) catch |err| {
                input.deinit();
                bun.default_allocator.destroy(self);
                return err;
            };

            self.* = .{
                .completion = completion,
                .input = input,
                .job = .{
                    .pipeline = image.pipeline,
                    .input = .none,
                    .kind = kind,
                    .max_pixels = image.max_pixels,
                    .auto_orient = image.auto_orient,
                    .result = initial_result orelse .{ .err = error.DecodeFailed },
                },
            };
            self.job.input = self.input.view();
            if (initial_result != null) {
                self.completion.complete(self);
            } else {
                self.schedule(background_tasks);
            }
        }

        pub const PreparedBlobRead = struct {
            blob: *bun.webcore.Blob,
            chain: *BlobReadChain,
            owner: *Self,

            pub fn abort(this: PreparedBlobRead) void {
                bun.destroy(this.chain);
                this.owner.completion.release();
                this.owner.deinit();
            }
        };

        pub fn prepareBlobRead(
            image: *Image,
            background_tasks: *bun.BackgroundTaskGroup,
            context: bindgen.CallContext(FunctionSchema),
            wrapper: bindgen.ClassRef(ImageClassSchema),
            kind: PipelineKind,
            destination_value: ?OwnedWriteDestination,
        ) bindgen.CallError(FunctionSchema)!PreparedBlobRead {
            var wrapper_owner = wrapper;
            var destination = destination_value;
            const blob = &image.source.blob;

            const self = bun.default_allocator.create(Self) catch {
                wrapper_owner.deinit();
                if (destination) |*value| value.deinit();
                return error.OutOfMemory;
            };
            const chain = bun.default_allocator.create(BlobReadChain) catch {
                bun.default_allocator.destroy(self);
                wrapper_owner.deinit();
                if (destination) |*value| value.deinit();
                return error.OutOfMemory;
            };

            var completion_view = context.completion();
            const completion = Completion.take(&completion_view, .{
                .wrapper = wrapper_owner.take(),
                .destination = if (destination) |*value| value.take() else null,
                .cache_blob_source = true,
            }) catch |err| {
                bun.default_allocator.destroy(chain);
                bun.default_allocator.destroy(self);
                return err;
            };

            self.* = .{
                .completion = completion,
                .input = .none,
                .job = .{
                    .pipeline = image.pipeline,
                    .input = .none,
                    .kind = kind,
                    .max_pixels = image.max_pixels,
                    .auto_orient = image.auto_orient,
                },
            };
            chain.* = .{
                .owner = self,
                .background_tasks = background_tasks,
            };
            return .{ .blob = blob, .chain = chain, .owner = self };
        }

        pub fn schedule(self: *Self, background_tasks: *bun.BackgroundTaskGroup) void {
            bun.BackgroundWork.schedule(background_tasks, &self.task) catch |err| {
                self.job.result = .{ .err = switch (err) {
                    error.ConcurrencyUnavailable => error.ConcurrencyUnavailable,
                    else => unreachable,
                } };
                self.completion.complete(self);
            };
        }

        fn runInBackground(task: *bun.BackgroundTaskGroup.Task) void {
            const self: *Self = @fieldParentPtr("task", task);
            self.job.run();
            self.completion.complete(self);
        }

        fn cancel(task: *bun.BackgroundTaskGroup.Task) void {
            const self: *Self = @fieldParentPtr("task", task);
            self.job.result = .{ .err = error.ConcurrencyUnavailable };
            self.completion.complete(self);
        }

        fn deinit(self: *Self) void {
            self.job.deinitResult();
            self.input.deinit();
            bun.default_allocator.destroy(self);
        }
    };
}

// ───────────────────────────── imports ──────────────────────────────────────

const codecs = @import("./codecs.zig");
const exif = @import("./exif.zig");
const std = @import("std");
const thumbhash = @import("./thumbhash.zig");

const bun = @import("bun");
const bindgen = bun.bindgen;

const ImageBindingModule = bindgen.Module("Image");
pub const ImageClassSchema = ImageBindingModule.class("Image");
const ImageClass = bindgen.Class(ImageClassSchema, JSBinding);
const ImageConstructorSchema = ImageClassSchema.constructor();
const ImageInputSchema = ImageClassSchema.memberKind("input", .getter);
const ImageAvifSchema = ImageClassSchema.memberKind("avif", .method);
const ImageBlobNativeSchema = ImageClassSchema.memberKind("blobNative", .method);
const ImageBufferSchema = ImageClassSchema.memberKind("buffer", .method);
const ImageBytesSchema = ImageClassSchema.memberKind("bytes", .method);
pub const SourceBufferInput = @FieldType(bindgen.Args(ImageBytesSchema), "source_buffer");
const ImageDataURLSchema = ImageClassSchema.memberKind("dataurl", .method);
const ImageFlipSchema = ImageClassSchema.memberKind("flip", .method);
const ImageFlopSchema = ImageClassSchema.memberKind("flop", .method);
const ImageHeicSchema = ImageClassSchema.memberKind("heic", .method);
const ImageHeightSchema = ImageClassSchema.memberKind("height", .getter);
const ImageJpegSchema = ImageClassSchema.memberKind("jpeg", .method);
const ImageMetadataSchema = ImageClassSchema.memberKind("metadata", .method);
const ImageModulateSchema = ImageClassSchema.memberKind("modulate", .method);
const ImagePlaceholderSchema = ImageClassSchema.memberKind("placeholder", .method);
const ImagePngSchema = ImageClassSchema.memberKind("png", .method);
const ImageResizeSchema = ImageClassSchema.memberKind("resize", .method);
const ImageRotateSchema = ImageClassSchema.memberKind("rotate", .method);
const ImageToBase64Schema = ImageClassSchema.memberKind("toBase64", .method);
const ImageToBufferSchema = ImageClassSchema.memberKind("toBuffer", .method);
const ImageWebpSchema = ImageClassSchema.memberKind("webp", .method);
const ImageWidthSchema = ImageClassSchema.memberKind("width", .getter);
const ImageWriteNativeSchema = ImageClassSchema.memberKind("writeNative", .method);
pub const async_pipeline_schemas = .{
    .{ .implementation = "bindBlobNative", .schema = ImageBlobNativeSchema },
    .{ .implementation = "bindBuffer", .schema = ImageBufferSchema },
    .{ .implementation = "bindBytes", .schema = ImageBytesSchema },
    .{ .implementation = "bindDataURL", .schema = ImageDataURLSchema },
    .{ .implementation = "bindMetadata", .schema = ImageMetadataSchema },
    .{ .implementation = "bindPlaceholder", .schema = ImagePlaceholderSchema },
    .{ .implementation = "bindToBase64", .schema = ImageToBase64Schema },
    .{ .implementation = "bindToBuffer", .schema = ImageToBufferSchema },
    .{ .implementation = "bindWriteNative", .schema = ImageWriteNativeSchema },
};
const ImageBackendGetterSchema = ImageClassSchema.memberKind("backend", .static_getter);
const ImageBackendSetterSchema = ImageClassSchema.memberKind("backend", .static_setter);
const ImageBackend = bindgen.Return(ImageBackendGetterSchema);
const ImageClipboardChangeCountSchema = ImageClassSchema.memberKind("clipboardChangeCount", .static_method);
const ImageFromClipboardSchema = ImageClassSchema.memberKind("fromClipboard", .static_method);
const ImageHasClipboardImageSchema = ImageClassSchema.memberKind("hasClipboardImage", .static_method);

comptime {
    _ = ImageClass;
}
