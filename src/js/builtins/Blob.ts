interface Blob {
  $statSourceNative(): "none" | "file" | "s3";
  $statFileNative(): Promise<object | undefined>;
  $statS3Native(): Promise<object>;
  $streamCache: ReadableStream | undefined;
  $streamNative(chunkSize?: number): { stream: ReadableStream; cache: boolean };
}

export function stat(this: Blob) {
  switch (this.$statSourceNative()) {
    case "file":
      return this.$statFileNative();
    case "s3":
      return this.$statS3Native();
    default:
      return undefined;
  }
}

export function stream(this: Blob, chunkSize?: number) {
  let stream = this.$streamCache;
  if (stream === undefined) {
    const result = this.$streamNative(chunkSize);
    stream = result.stream;
    if (result.cache) this.$streamCache = stream;
  }
  return stream;
}
