type InternalReadableStreamPullValue = Uint8Array | number | false;
interface InternalReadableStreamSettledPullResult {
  value: InternalReadableStreamPullValue;
  done: boolean;
}

interface InternalReadableStreamSource {
  $pullNative(view?: Uint8Array): {
    value: InternalReadableStreamPullValue | Promise<InternalReadableStreamSettledPullResult> | undefined;
    done: boolean;
  };
}

export function pull(this: InternalReadableStreamSource, view?: Uint8Array, flags?: [boolean]) {
  const result = this.$pullNative(view);
  if (result.done && flags !== undefined) flags[0] = true;
  if ($isPromise(result.value)) {
    return result.value.$then(settled => {
      if (settled.done && flags !== undefined) flags[0] = true;
      return settled.value;
    });
  }
  return result.value;
}
