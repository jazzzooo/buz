interface BindgenTestCounter {
  $pull(delta: unknown): number;
  increment(delta?: unknown): number;
}

export function builtinAdd(a: unknown, b: unknown) {
  const add: (a: unknown, b: unknown) => number = $bindgenFn("bindgen_test.schema.zig", "add");
  return add(a, b) * 2;
}

export function counterIncrement(this: BindgenTestCounter, delta: unknown) {
  return this.$pull(delta) * 2;
}

$getter;
export function counterDoubled(this: BindgenTestCounter) {
  return this.increment(0) * 2;
}
