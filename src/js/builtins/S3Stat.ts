interface S3Stat {
  $lastModifiedText(): string;
}

export function lastModified(this: S3Stat) {
  return new Date(this.$lastModifiedText());
}
