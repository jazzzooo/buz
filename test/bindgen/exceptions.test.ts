import { bindgen, nodeErrors } from "bun:internal-for-testing";
import { expect, test } from "bun:test";

test("native promise settlement preserves a pending exception without settling the promise", () => {
  for (const settlement of ["resolve", "reject", "rejectHandled"]) {
    for (const failure of [undefined, new Error("pending failure")]) {
      const { promise, resolve } = Promise.withResolvers();
      promise.catch(() => {});
      let caught: unknown;
      let didThrow = false;
      try {
        nodeErrors.settlePromiseWithPendingException(promise, failure, settlement);
      } catch (error) {
        didThrow = true;
        caught = error;
      }
      expect(didThrow).toBe(true);
      expect(caught).toBe(failure);
      expect(Bun.peek.status(promise)).toBe("pending");
      resolve("finished");
      expect(Bun.peek(promise)).toBe("finished");
    }
  }
});

test("out-of-memory materialization preserves an already pending exception", () => {
  for (const failure of [undefined, 42, Symbol("failure"), new Error("failure")]) {
    let caught: unknown;
    let didThrow = false;
    try {
      nodeErrors.throwOutOfMemoryWithPendingException(failure);
    } catch (error) {
      didThrow = true;
      caught = error;
    }
    expect(didThrow).toBe(true);
    expect(caught).toBe(failure);
  }
  let caught: unknown;
  try {
    nodeErrors.throwOutOfMemoryWithPendingException();
  } catch (error) {
    caught = error;
  }
  expect(caught).toBeInstanceOf(Error);
  expect(caught).not.toBeInstanceOf(RangeError);
  expect((caught as Error).message).toBe("Out of memory");
});

test("receiver diagnostics preserve custom inspection failures", () => {
  for (const injectOOM of [false, true]) {
    let failure = new Error("custom inspection failed");
    let calls = 0;
    const input = Object.assign(Object.create(null), {
      [Bun.inspect.custom]() {
        calls++;
        if (injectOOM) {
          bindgen.setTransferAllocationFailureCountdown(0);
          try {
            bindgen.echoTestScalars([1]);
          } catch (error) {
            failure = error as Error;
            throw error;
          } finally {
            bindgen.setTransferAllocationFailureCountdown(-1);
          }
        }
        throw failure;
      },
    });
    let caught: unknown;
    try {
      bindgen.Counter.prototype.increment.call(input);
    } catch (error) {
      caught = error;
    }
    expect(calls).toBe(1);
    expect(caught).toBe(failure);
  }
  expect(Bun.inspect({ after: "inspection failure" })).toContain("inspection failure");
});

test("receiver diagnostics preserve constructor getter failures", () => {
  const failure = new Error("constructor getter failed");
  const input = {
    get constructor() {
      throw failure;
    },
  };
  let caught: unknown;
  try {
    bindgen.Counter.prototype.increment.call(input);
  } catch (error) {
    caught = error;
  }
  expect(caught).toBe(failure);
});
