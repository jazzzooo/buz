// @internal

export function createS3Error(payload) {
  return $bindgenFn("S3Errors.schema.zig", "createS3Error")(payload);
}
