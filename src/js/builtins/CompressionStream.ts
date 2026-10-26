export function initializeCompressionStream(this, format) {
  const zlib = require("node:zlib");
  const stream = require("node:stream");

  const builders = {
    "deflate": zlib.createDeflate,
    "deflate-raw": zlib.createDeflateRaw,
    "gzip": zlib.createGzip,
    "brotli": zlib.createBrotliCompress,
    "zstd": zlib.createZstdCompress,
  };

  const handle = builders[format]();
  $putByIdDirectPrivate(this, "compressionStreamReadable", stream.Readable.toWeb(handle));
  $putByIdDirectPrivate(this, "compressionStreamWritable", stream.Writable.toWeb(handle));

  return this;
}

$getter;
export function readable(this) {
  const isCompressionStream = $bindgenFn<typeof BunNativeBindings.NativeTypePredicates.isCompressionStream>(
    "NativeTypePredicates.schema.zig",
    "isCompressionStream",
  );
  if (!isCompressionStream(this)) throw $makeGetterTypeError("CompressionStream", "readable");
  return $getByIdDirectPrivate(this, "compressionStreamReadable");
}

$getter;
export function writable(this) {
  const isCompressionStream = $bindgenFn<typeof BunNativeBindings.NativeTypePredicates.isCompressionStream>(
    "NativeTypePredicates.schema.zig",
    "isCompressionStream",
  );
  if (!isCompressionStream(this)) throw $makeGetterTypeError("CompressionStream", "writable");
  return $getByIdDirectPrivate(this, "compressionStreamWritable");
}
