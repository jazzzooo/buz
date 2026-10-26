// @internal
interface BunTestScopeFunction extends Function {
  $bunTestScopeState: object;
}

export function createBunTestScopeFunction(state: object, name: string): BunTestScopeFunction {
  const call = $bindgenFn("ScopeFunctions.schema.zig", "call");
  const scope = call.bind(state) as BunTestScopeFunction;
  $Object.$defineProperty(scope, "name", { value: name, configurable: true });
  $setPrototypeDirect.$call(scope, $getPrototypeOf(state));
  $putByIdDirectPrivate(scope, "bunTestScopeState", state);
  return scope;
}
