function named<T extends Function>(fn: T, name: string): T {
  Object.defineProperty(fn, "name", { value: name, configurable: true });
  return fn;
}

const test = $bindgenFn("BunTest.schema.zig", "createTestScope")();
const xtest = $bindgenFn("BunTest.schema.zig", "createSkippedTestScope")();
const describe = $bindgenFn("BunTest.schema.zig", "createDescribeScope")();
const xdescribe = $bindgenFn("BunTest.schema.zig", "createSkippedDescribeScope")();
const beforeEach = $bindgenFn("BunTest.schema.zig", "beforeEach");
const beforeAll = $bindgenFn("BunTest.schema.zig", "beforeAll");
const afterAll = $bindgenFn("BunTest.schema.zig", "afterAll");
const afterEach = $bindgenFn("BunTest.schema.zig", "afterEach");
const onTestFinished = $bindgenFn("BunTest.schema.zig", "onTestFinished");
const setDefaultTimeout = $bindgenFn("BunTest.schema.zig", "setDefaultTimeout");
const expect = $bindgenClass("Expect.schema.zig", "Expect");
const expectTypeOf = $bindgenClass("Expect.schema.zig", "ExpectTypeOf");

const setSystemTime = named($bindgenFn("JSMockHost.schema.zig", "JSMock__jsSetSystemTime"), "setSystemTime");
const mock = named($bindgenFn("JSMockHost.schema.zig", "JSMock__jsMockFn"), "fn");
const spyOn = named($bindgenFn("JSMockHost.schema.zig", "JSMock__jsSpyOn"), "spyOn");
const restoreAllMocks = named($bindgenFn("JSMockHost.schema.zig", "JSMock__jsRestoreAllMocks"), "restoreAllMocks");
const clearAllMocks = named($bindgenFn("JSMockHost.schema.zig", "JSMock__jsClearAllMocks"), "clearAllMocks");
const mockModule = named($bindgenFn("RuntimeFunctions.schema.zig", "JSMock__jsModuleMock"), "module");
const now = named($bindgenFn("JSMockHost.schema.zig", "JSMock__jsNow"), "now");

Object.assign(mock, {
  module: mockModule,
  restore: restoreAllMocks,
  clearAllMocks,
});

const useFakeTimersNative = $bindgenFn("FakeTimersConfig.schema.zig", "useFakeTimers");
const useRealTimersNative = $bindgenFn("FakeTimersConfig.schema.zig", "useRealTimers");
const advanceTimersToNextTimerNative = $bindgenFn("FakeTimersConfig.schema.zig", "advanceTimersToNextTimer");
const advanceTimersByTimeNative = $bindgenFn("FakeTimersConfig.schema.zig", "advanceTimersByTime");
const runOnlyPendingTimersNative = $bindgenFn("FakeTimersConfig.schema.zig", "runOnlyPendingTimers");
const runAllTimersNative = $bindgenFn("FakeTimersConfig.schema.zig", "runAllTimers");
const getTimerCount = $bindgenFn("FakeTimersConfig.schema.zig", "getTimerCount");
const clearAllTimersNative = $bindgenFn("FakeTimersConfig.schema.zig", "clearAllTimers");
const isFakeTimers = $bindgenFn("FakeTimersConfig.schema.zig", "isFakeTimers");

function useFakeTimers(options?: unknown) {
  useFakeTimersNative(options);
  const timeout = globalThis.setTimeout;
  if ($isObject(timeout)) (timeout as any).clock = true;
  return this;
}

function useRealTimers() {
  useRealTimersNative();
  const timeout = globalThis.setTimeout;
  if ($isObject(timeout)) delete (timeout as any).clock;
  return this;
}

function advanceTimersToNextTimer() {
  advanceTimersToNextTimerNative();
  return this;
}

function advanceTimersByTime(milliseconds: number) {
  advanceTimersByTimeNative(milliseconds);
  return this;
}

function runOnlyPendingTimers() {
  runOnlyPendingTimersNative();
  return this;
}

function runAllTimers() {
  runAllTimersNative();
  return this;
}

function clearAllTimers() {
  clearAllTimersNative();
  return this;
}

const setTimeout = function setTimeout(timeout: number) {
  return setDefaultTimeout(timeout);
};

const jest = {
  fn: mock,
  mock: mockModule,
  spyOn,
  restoreAllMocks,
  clearAllMocks,
  resetAllMocks: clearAllMocks,
  setSystemTime,
  now,
  setTimeout,
  useFakeTimers,
  useRealTimers,
  advanceTimersToNextTimer,
  advanceTimersByTime,
  runOnlyPendingTimers,
  runAllTimers,
  getTimerCount,
  clearAllTimers,
  isFakeTimers,
};

const vi = {
  fn: mock,
  mock: mockModule,
  spyOn,
  restoreAllMocks,
  resetAllMocks: clearAllMocks,
  clearAllMocks,
  useFakeTimers,
  useRealTimers,
  advanceTimersToNextTimer,
  advanceTimersByTime,
  runOnlyPendingTimers,
  runAllTimers,
  getTimerCount,
  clearAllTimers,
  isFakeTimers,
};

export default {
  test,
  it: test,
  xtest,
  xit: xtest,
  describe,
  xdescribe,
  beforeEach,
  beforeAll,
  afterAll,
  afterEach,
  onTestFinished,
  setDefaultTimeout,
  expect,
  expectTypeOf,
  setSystemTime,
  mock,
  jest,
  spyOn,
  vi,
};
