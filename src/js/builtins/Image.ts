interface ImageEncodedResult {
  data: Uint8Array;
  mime: string;
}

type ImageWriteDestination = Uint8Array | number | Blob;

interface ImageWriteResult {
  data: Uint8Array;
  destination: ImageWriteDestination;
}

interface Image {
  $blobNative(): Promise<ImageEncodedResult>;
  $writeNative(destination?): Promise<ImageWriteResult>;
}

export async function blob(this: Image) {
  const result = await this.$blobNative();
  return new Blob([result.data], { type: result.mime });
}

export async function write(this: Image, destination?) {
  const result = await this.$writeNative(destination);
  return Bun.write(result.destination, result.data);
}
