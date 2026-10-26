interface Subprocess {
  $asyncDisposeNative(): void;
  exited: Promise<number>;
}

export async function asyncDispose(this: Subprocess) {
  this.$asyncDisposeNative();
  await this.exited;
}
