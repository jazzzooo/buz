interface BuildArtifact {
  $blobValue(): Blob;
  $streamCache: ReadableStream | undefined;
  $streamNative(chunkSize?: number): { stream: ReadableStream; cache: boolean };
}

export function arrayBuffer(this: BuildArtifact) {
  return this.$blobValue().arrayBuffer();
}

export function json(this: BuildArtifact) {
  return this.$blobValue().json();
}

export function stream(this: BuildArtifact, chunkSize?: number) {
  let stream = this.$streamCache;
  if (stream === undefined) {
    const result = this.$streamNative(chunkSize);
    stream = result.stream;
    if (result.cache) this.$streamCache = stream;
  }
  return stream;
}

export function text(this: BuildArtifact) {
  return this.$blobValue().text();
}
