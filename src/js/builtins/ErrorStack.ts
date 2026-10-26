$visibility = "Private";
export function createRecursiveStackAccessor(error, callSites) {
  return {
    get stack() {
      return $bindgenFn("RuntimeFunctions.schema.zig", "jsFunctionDefaultErrorPrepareStackTrace")(error, callSites);
    },
    set stack(value) {
      $Object.$defineProperty(this, "stack", { value, writable: true, enumerable: false, configurable: true });
    },
  };
}
