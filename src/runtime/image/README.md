# `Bun.Image`

Sharp-shaped image pipeline. Decode → (auto-orient) → transform\* → encode, all
off the JS thread.

## Layout

| file                                  | owns                                                                                                            | touch when                               |
| ------------------------------------- | --------------------------------------------------------------------------------------------------------------- | ---------------------------------------- |
| `Image.schema.zig`                   | JS surface (codegen input)                                                                                      | adding/renaming a JS method              |
| `Image.zig`                           | JS↔Zig glue: arg parsing, op recording, schema-completion scheduling, result delivery                           | new options, new chainable, new terminal |
| `codecs.zig`                          | thin `extern fn` wrappers over libjpeg-turbo / libspng / libwebp + the `Format` sniffer + the pixel-limit guard | bumping a codec, adding a format         |
| `exif.zig`                            | JPEG APP1/TIFF Orientation reader (tag 0x0112 only)                                                             | extending EXIF coverage                  |
| `quantize.zig`                        | median-cut RGBA → palette for `png({palette})`                                                                  | dithering, perceptual weighting          |
| `backend_coregraphics.zig`            | macOS ImageIO/CoreGraphics, lazy `dlopen`                                                                       | macOS-specific behaviour                 |
| `backend_wic.zig`                     | Windows WIC, COM                                                                                                | Windows-specific behaviour               |
| `../../image_sys/` | Native image library: shared C header, Highway kernels, and SDK-backed platform adapters | native codec interfaces and kernels |

`system_backend` in `codecs.zig` is `?type` — `null` on Linux so the dispatch
compiles away. On macOS/Windows the backend is tried first; it returns
`error.BackendUnavailable` for anything it can't do (palette PNG, lossless
WebP, dlopen miss) and the static path takes over.

The codecs themselves are vendored via `scripts/build/deps/{libjpeg-turbo,libspng,libwebp}.ts`.
`patches/libjpeg-turbo/` carries the 8-bit-only patch + the j12/j16 stub overlay.

## Adding a chainable op

1. Add a field to `Pipeline` in `Image.zig` (one slot per op — setters
   overwrite, there is no op list) and a stage in `PipelineJob.applyPipeline`
   at the right point in the fixed `rotate → flip/flop → resize → modulate`
   order.
2. Add a `do<Name>` method that performs the operation and a typed
   `bind<Name>` adapter for the schema declaration.
3. Add it to the `Image` class declaration in `Image.schema.zig`.
4. Declare native kernels in `src/image_sys/BunImage.h` and implement them
   in `src/image_sys/Kernels.cpp`. Zig consumes the translated `image-ffi` module.

## Adding a format

1. New `scripts/build/deps/<lib>.ts` (copy `libspng.ts` for the simple case).
2. Extend `Format` + `sniff()` + `mime()` in `codecs.zig`, add a `pub const
<fmt> = struct { decode/encode }` block alongside the others.
3. If the format carries EXIF, extend `exif.zig`.
4. `LICENSE.md` row.

## Invariants

- Pixel format is **RGBA8 everywhere** between decode and encode. Decoders are
  configured to emit it; encoders are fed it. Nothing branches on channels.
- **Decode** output is `bun.default_allocator`-owned `[]u8`. **Encode** output
  is `Encoded{bytes, free}` where `free` is the _codec's_ deallocator
  (`tj3Free`/`WebPFree`/`std.c.free`/`mi_free`); `then()` hands that buffer
  straight to JS via `ArrayBuffer.toJSWithContext(..., free)` — no dupe. New
  codecs return `Encoded` with the right `free`, not a default_allocator slice.
- The `max_pixels` guard fires **after the header read, before the RGBA alloc**
  in every codec. New codecs must do the same.
- `src/image_sys/Kernels.cpp` must stay in `no_unify` in `src/build/exe.zig` —
  highway's `foreach_target.h` has a TU-wide include guard that breaks with
  two highway TUs in one bundle.
