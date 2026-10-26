export function initializeDecompressionStream(this, format) {
  const zlib = require("node:zlib");
  const stream = require("node:stream");

  const builders = {
    "deflate": zlib.createInflate,
    "deflate-raw": zlib.createInflateRaw,
    "gzip": zlib.createGunzip,
    "brotli": zlib.createBrotliDecompress,
    "zstd": zlib.createZstdDecompress,
  };

  const handle = builders[format]();
  $putByIdDirectPrivate(this, "decompressionStreamReadable", stream.Readable.toWeb(handle));
  $putByIdDirectPrivate(this, "decompressionStreamWritable", stream.Writable.toWeb(handle));

  return this;
}

$getter;
export function readable(this) {
  const isDecompressionStream = $bindgenFn<typeof BunNativeBindings.NativeTypePredicates.isDecompressionStream>(
    "NativeTypePredicates.schema.zig",
    "isDecompressionStream",
  );
  if (!isDecompressionStream(this)) throw $makeGetterTypeError("DecompressionStream", "readable");
  return $getByIdDirectPrivate(this, "decompressionStreamReadable");
}

$getter;
export function writable(this) {
  const isDecompressionStream = $bindgenFn<typeof BunNativeBindings.NativeTypePredicates.isDecompressionStream>(
    "NativeTypePredicates.schema.zig",
    "isDecompressionStream",
  );
  if (!isDecompressionStream(this)) throw $makeGetterTypeError("DecompressionStream", "writable");
  return $getByIdDirectPrivate(this, "decompressionStreamWritable");
}
