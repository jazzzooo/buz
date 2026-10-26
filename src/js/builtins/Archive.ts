interface ArchiveFileEntry {
  path: string;
  data: Uint8Array;
  mtime: number;
}

interface Archive {
  $blobNative(): Promise<Uint8Array>;
  $filesNative(glob?): Promise<ArchiveFileEntry[]>;
}

export async function blob(this: Archive) {
  return new Blob([await this.$blobNative()]);
}

export async function files(this: Archive, glob?) {
  const entries = await this.$filesNative(glob);
  const files = new Map<string, File>();
  for (const entry of entries) {
    files.set(entry.path, new File([entry.data], entry.path, { lastModified: entry.mtime * 1000 }));
  }
  return files;
}
