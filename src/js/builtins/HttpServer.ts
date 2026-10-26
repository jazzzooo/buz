interface HTTPServer {
  $fetchNative(input, options): Promise<unknown>;
  $stopNative(abrupt): Promise<void>;
}

export async function fetch(this: HTTPServer, input, options) {
  return await this.$fetchNative.$apply(this, arguments);
}

export async function stop(this: HTTPServer, abrupt) {
  await this.$stopNative(abrupt);
}
