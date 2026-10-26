$visibility = "Private";

export function createModuleMock(callback, specifier) {
  let state = 0;
  let cached;

  function finish(value) {
    if (!$isObject(value)) {
      throw new TypeError("mock(module, fn) requires a function that returns an object");
    }
    $bindgenFn("RuntimeFunctions.schema.zig", "applyModuleMock")(specifier, execute, value);
    return value;
  }

  function execute() {
    if (state === 1) throw new TypeError("Cannot recursively evaluate a module mock factory");
    if (state === 2) return cached;
    if (state === 3) throw cached;

    state = 1;
    try {
      let value = callback.$call(undefined);
      while ($isPromise(value) && $peekPromiseStatus(value) === 1) {
        value = $peekPromiseSettledValue(value);
      }
      if ($isPromise(value)) {
        if ($peekPromiseStatus(value) === 2) {
          $markPromiseAsHandled(value);
          throw $peekPromiseSettledValue(value);
        }
        cached = $bindgenFn("promises.schema.zig", "chain")(value, finish, undefined);
      } else {
        cached = finish(value);
      }
      state = 2;
      return cached;
    } catch (error) {
      cached = error;
      state = 3;
      throw error;
    } finally {
      callback = undefined;
    }
  }

  return execute;
}
