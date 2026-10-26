interface Terminal {
  $asyncDisposeNative(): void;
}

export async function asyncDispose(this: Terminal) {
  const result: any = this.$asyncDisposeNative();
  if (result !== undefined) await result;
}
