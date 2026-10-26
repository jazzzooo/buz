$visibility = "Private";

export function chainVirtualModule(promise, specifier, referrer, wasModuleMock) {
  return $bindgenFn("promises.schema.zig", "chain")(
    promise,
    result => $bindgenFn("RuntimeFunctions.schema.zig", "completeVirtualModule")(result, specifier, referrer, wasModuleMock),
    undefined,
  );
}
