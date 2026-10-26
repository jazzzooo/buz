export function expect(value?: unknown, customLabel?: unknown) {
  let label = "";
  if (typeof customLabel === "string") {
    label = customLabel;
  } else if ($isObject(customLabel) && $isCallable((customLabel as any).toString)) {
    label = $toString(customLabel);
  }
  return $bindgenFn("Expect.schema.zig", "createExpect")(value, label);
}

interface BunTestScopeFunction extends Function {
  $bunTestScopeConcurrent: BunTestScopeFunction | undefined;
  $bunTestScopeFailing: BunTestScopeFunction | undefined;
  $bunTestScopeOnly: BunTestScopeFunction | undefined;
  $bunTestScopeSerial: BunTestScopeFunction | undefined;
  $bunTestScopeSkip: BunTestScopeFunction | undefined;
  $bunTestScopeState: object;
  $bunTestScopeTodo: BunTestScopeFunction | undefined;
}

export function createTestScope() {
  return $createBunTestScopeFunction($bindgenFn("ScopeFunctions.schema.zig", "createTestState")(), "test");
}

export function createSkippedTestScope() {
  return $createBunTestScopeFunction($bindgenFn("ScopeFunctions.schema.zig", "createSkippedTestState")(), "xtest");
}

export function createDescribeScope() {
  return $createBunTestScopeFunction($bindgenFn("ScopeFunctions.schema.zig", "createDescribeState")(), "describe");
}

export function createSkippedDescribeScope() {
  return $createBunTestScopeFunction(
    $bindgenFn("ScopeFunctions.schema.zig", "createSkippedDescribeState")(),
    "xdescribe",
  );
}

$getter;
export function scopeConcurrent(this: BunTestScopeFunction) {
  let scope = $getByIdDirectPrivate(this, "bunTestScopeConcurrent");
  if (scope === undefined) {
    scope = $createBunTestScopeFunction(
      $bindgenFn("ScopeFunctions.schema.zig", "deriveConcurrent")(
        $getByIdDirectPrivate(this, "bunTestScopeState"),
      ),
      "concurrent",
    );
    $putByIdDirectPrivate(this, "bunTestScopeConcurrent", scope);
  }
  return scope;
}

export function scopeConcurrentIf(this: BunTestScopeFunction, condition?: unknown) {
  const derive = $bindgenFn("ScopeFunctions.schema.zig", "deriveConcurrentIf");
  const state = $getByIdDirectPrivate(this, "bunTestScopeState");
  return $createBunTestScopeFunction(
    $argumentCount() === 0 ? derive(state) : derive(state, condition),
    "concurrentIf",
  );
}

export function scopeEach(this: BunTestScopeFunction, array: unknown[]) {
  const derive = $bindgenFn("ScopeFunctions.schema.zig", "deriveEach");
  const state = $getByIdDirectPrivate(this, "bunTestScopeState");
  return $createBunTestScopeFunction(
    $argumentCount() === 0 ? derive(state) : derive(state, array),
    "each",
  );
}

$getter;
export function scopeFailing(this: BunTestScopeFunction) {
  let scope = $getByIdDirectPrivate(this, "bunTestScopeFailing");
  if (scope === undefined) {
    scope = $createBunTestScopeFunction(
      $bindgenFn("ScopeFunctions.schema.zig", "deriveFailing")($getByIdDirectPrivate(this, "bunTestScopeState")),
      "failing",
    );
    $putByIdDirectPrivate(this, "bunTestScopeFailing", scope);
  }
  return scope;
}

export function scopeFailingIf(this: BunTestScopeFunction, condition?: unknown) {
  const derive = $bindgenFn("ScopeFunctions.schema.zig", "deriveFailingIf");
  const state = $getByIdDirectPrivate(this, "bunTestScopeState");
  return $createBunTestScopeFunction(
    $argumentCount() === 0 ? derive(state) : derive(state, condition),
    "failingIf",
  );
}

export function scopeIf(this: BunTestScopeFunction, condition?: unknown) {
  const derive = $bindgenFn("ScopeFunctions.schema.zig", "deriveIf");
  const state = $getByIdDirectPrivate(this, "bunTestScopeState");
  return $createBunTestScopeFunction(
    $argumentCount() === 0 ? derive(state) : derive(state, condition),
    "if",
  );
}

$getter;
export function scopeOnly(this: BunTestScopeFunction) {
  let scope = $getByIdDirectPrivate(this, "bunTestScopeOnly");
  if (scope === undefined) {
    scope = $createBunTestScopeFunction(
      $bindgenFn("ScopeFunctions.schema.zig", "deriveOnly")($getByIdDirectPrivate(this, "bunTestScopeState")),
      "only",
    );
    $putByIdDirectPrivate(this, "bunTestScopeOnly", scope);
  }
  return scope;
}

$getter;
export function scopeSerial(this: BunTestScopeFunction) {
  let scope = $getByIdDirectPrivate(this, "bunTestScopeSerial");
  if (scope === undefined) {
    scope = $createBunTestScopeFunction(
      $bindgenFn("ScopeFunctions.schema.zig", "deriveSerial")($getByIdDirectPrivate(this, "bunTestScopeState")),
      "serial",
    );
    $putByIdDirectPrivate(this, "bunTestScopeSerial", scope);
  }
  return scope;
}

export function scopeSerialIf(this: BunTestScopeFunction, condition?: unknown) {
  const derive = $bindgenFn("ScopeFunctions.schema.zig", "deriveSerialIf");
  const state = $getByIdDirectPrivate(this, "bunTestScopeState");
  return $createBunTestScopeFunction(
    $argumentCount() === 0 ? derive(state) : derive(state, condition),
    "serialIf",
  );
}

$getter;
export function scopeSkip(this: BunTestScopeFunction) {
  let scope = $getByIdDirectPrivate(this, "bunTestScopeSkip");
  if (scope === undefined) {
    scope = $createBunTestScopeFunction(
      $bindgenFn("ScopeFunctions.schema.zig", "deriveSkip")($getByIdDirectPrivate(this, "bunTestScopeState")),
      "skip",
    );
    $putByIdDirectPrivate(this, "bunTestScopeSkip", scope);
  }
  return scope;
}

export function scopeSkipIf(this: BunTestScopeFunction, condition?: unknown) {
  const derive = $bindgenFn("ScopeFunctions.schema.zig", "deriveSkipIf");
  const state = $getByIdDirectPrivate(this, "bunTestScopeState");
  return $createBunTestScopeFunction(
    $argumentCount() === 0 ? derive(state) : derive(state, condition),
    "skipIf",
  );
}

$getter;
export function scopeTodo(this: BunTestScopeFunction) {
  let scope = $getByIdDirectPrivate(this, "bunTestScopeTodo");
  if (scope === undefined) {
    scope = $createBunTestScopeFunction(
      $bindgenFn("ScopeFunctions.schema.zig", "deriveTodo")($getByIdDirectPrivate(this, "bunTestScopeState")),
      "todo",
    );
    $putByIdDirectPrivate(this, "bunTestScopeTodo", scope);
  }
  return scope;
}

export function scopeTodoIf(this: BunTestScopeFunction, condition?: unknown) {
  const derive = $bindgenFn("ScopeFunctions.schema.zig", "deriveTodoIf");
  const state = $getByIdDirectPrivate(this, "bunTestScopeState");
  return $createBunTestScopeFunction(
    $argumentCount() === 0 ? derive(state) : derive(state, condition),
    "todoIf",
  );
}
