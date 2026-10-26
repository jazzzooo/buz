interface Listener {
  $getSockNameNative(result): { family: string; address: string; port: number } | undefined;
}

export function getSockName(this: Listener, result) {
  const address = this.$getSockNameNative(result);
  if (address !== undefined) {
    result.family = address.family;
    result.address = address.address;
    result.port = address.port;
  }
}
