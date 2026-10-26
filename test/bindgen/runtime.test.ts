import {
  bindgen,
  bindgenBuiltinAdd,
  bindgenCppAdd,
  bindgenCppBufferLength,
  bindgenCppDictionarySourceSequenceLength,
  bindgenCppClassifyNullableFieldPresence,
  bindgenCppCallZigExport,
  bindgenCppCallZigNativeString,
  bindgenCppCallZigNativeRecord,
  bindgenCppClassifyNullablePresence,
  bindgenCppEchoBuffer,
  bindgenCppEchoString,
  bindgenCppExternalRefPresent,
  bindgenCppExternalRefSequenceLength,
  bindgenCppInspectRest,
  bindgenCppLazyStringLength,
  bindgenCppOptionalUnionPresent,
  bindgenCppOverload,
  bindgenCppSumIntegerWidths,
  structuredCloneAdvanced,
} from "bun:internal-for-testing";
import { expect, it } from "bun:test";
import { AsyncLocalStorage } from "node:async_hooks";

function withTransferFailures<T>(operation: () => T): T {
  for (let countdown = 0; countdown < 64; countdown++) {
    let result: T;
    bindgen.setTransferAllocationFailureCountdown(countdown);
    try {
      result = operation();
    } catch (error) {
      expect(error).toBeInstanceOf(Error);
      expect(error).not.toBeInstanceOf(RangeError);
      expect((error as Error).message).toBe("Out of memory");
      continue;
    } finally {
      bindgen.setTransferAllocationFailureCountdown(-1);
    }
    expect(countdown).toBeGreaterThan(0);
    return result;
  }
  throw new Error("Transfer did not succeed after exhausting allocation failures");
}

function terminateWorker(worker: Worker): Promise<void> {
  return new Promise(resolve => {
    worker.addEventListener("close", () => resolve(), { once: true });
    worker.terminate();
  });
}

it("supports every fixed-width integer across Zig, callbacks, C++, and engine shims", () => {
  expect(bindgen.echoInt8(-128)).toBe(-128);
  expect(bindgen.echoInt8(127)).toBe(127);
  expect(bindgen.echoInt16(-32768)).toBe(-32768);
  expect(bindgen.echoInt16(32767)).toBe(32767);
  expect(bindgen.echoUint16(0)).toBe(0);
  expect(bindgen.echoUint16(65535)).toBe(65535);
  expect(bindgen.echoUint32(4294967295)).toBe(4294967295);
  expect(bindgen.echoInt64(-Number.MAX_SAFE_INTEGER)).toBe(-Number.MAX_SAFE_INTEGER);
  expect(bindgen.echoUint64(Number.MAX_SAFE_INTEGER)).toBe(Number.MAX_SAFE_INTEGER);
  expect(() => bindgen.echoUint64(42n)).toThrow();

  expect(() => bindgen.echoInt8(128)).toThrow();
  expect(() => bindgen.echoUint16(-1)).toThrow();
  expect(() => bindgen.echoUint32(-1)).toThrow();
  expect(() => bindgen.echoUint32(4294967296)).toThrow();
  expect(() => bindgen.echoInt64(2 ** 63)).toThrow();
  expect(() => bindgen.echoUint64(-1)).toThrow();

  const values = [-2, -300, 500, 70000, -90000, 100000] as const;
  expect(
    bindgen.invokeIntegerCallback(
      (...received) => {
        expect(received).toEqual(values);
        return 123456;
      },
      ...values,
    ),
  ).toBe(123456);
  expect(bindgen.sumIntegerWidthsViaEngine(...values)).toBe(80198);
  expect(bindgenCppSumIntegerWidths(...values)).toBe(80198);
});

it("round-trips an advanced generated type graph through Zig, C++, and typed callbacks", () => {
  let recordGetterCalls = 0;
  const lookup = Object.create(
    { inherited: 99 },
    {
      alpha: { value: 3, enumerable: true },
      beta: {
        enumerable: true,
        get() {
          recordGetterCalls++;
          return "four 😀";
        },
      },
      hidden: { value: false, enumerable: false },
    },
  );
  const input = {
    metadata: { mode: "safe-mode" as const, note: "meta 😀" },
    scalars: [1, "two", false] as const,
    lookup,
  };
  const expected = {
    metadata: { mode: "safe-mode", note: "meta 😀" },
    scalars: [1, "two", false],
    lookup: { alpha: 3, beta: "four 😀" },
  };

  expect(bindgen.roundTripTestBundle(input)).toEqual(expected);
  expect(recordGetterCalls).toBe(1);

  let callbackCalls = 0;
  expect(
    bindgen.visitTestBundle(input, bundle => {
      callbackCalls++;
      expect(bundle).toEqual(expected);
      return 0x1234;
    }),
  ).toBe(0x1234);
  expect(callbackCalls).toBe(1);
  expect(recordGetterCalls).toBe(2);
  expect(bindgenCppCallZigExport(6, 7, 4)).toBe(46);
  expect(bindgen.dispatchAdvanced(new Uint8Array([1, 2, 3]), "x")).toBe(308);
  expect(
    bindgen.dispatchAdvanced(
      {
        count: 4,
        metadata: { mode: "fast" },
      },
      "x",
    ),
  ).toBe(408);
  expect(() => bindgen.dispatchAdvanced(42 as any, "x")).toThrow("No overload");

  expect(() => bindgen.roundTripTestBundle({ ...input, metadata: { mode: "invalid" as any } })).toThrow(TypeError);
  expect(() => bindgen.roundTripTestBundle({ ...input, scalars: [{} as any] })).toThrow(
    "does not match any union member",
  );

  const callbackError = new Error("callback failed");
  expect(() =>
    bindgen.visitTestBundle(input, () => {
      throw callbackError;
    }),
  ).toThrow(callbackError);
  expect(withTransferFailures(() => bindgen.roundTripTestBundle(input))).toEqual(expected);
  expect(bindgen.roundTripTestBundle(input)).toEqual(expected);
});

it("schema builtins reach native code through bindgen functions", () => {
  expect(bindgenBuiltinAdd(5, 3)).toBe(16);
  expect(bindgenBuiltinAdd(null, "4")).toBe(8);
});

it("schema C++ backends receive converted values in frame", () => {
  expect(bindgenCppAdd(5, 3)).toBe(8);
  expect(() => bindgenCppAdd("5", 3)).toThrow();
  expect(bindgenCppOverload(42)).toBe(42);
  expect(bindgenCppOverload("hello")).toBe(5);
  expect(() => bindgenCppOverload({} as string)).toThrow();
  expect(bindgenCppEchoString("hello")).toBe("hello");
  expect(() => bindgenCppEchoString(42)).toThrow();
  expect(bindgenCppBufferLength(new Uint16Array(3))).toBe(6);
  expect(bindgenCppDictionarySourceSequenceLength([{}, { value: 1 }])).toBe(2);
  expect(bindgenCppExternalRefPresent(new AbortController().signal)).toBe(true);
  expect(bindgenCppExternalRefSequenceLength([new AbortController().signal, new AbortController().signal])).toBe(2);
  expect(bindgenCppOptionalUnionPresent("present")).toBe(true);
  expect(bindgenCppOptionalUnionPresent(undefined)).toBe(false);
  expect(bindgenCppOptionalUnionPresent(1)).toBe(false);
  expect(bindgenCppClassifyNullablePresence()).toBe(0);
  expect(bindgenCppClassifyNullablePresence(null)).toBe(1);
  expect(bindgenCppClassifyNullablePresence(5)).toBe(7);
  expect(bindgenCppClassifyNullableFieldPresence({})).toBe(0);
  expect(bindgenCppClassifyNullableFieldPresence({ input: null })).toBe(1);
  expect(bindgenCppClassifyNullableFieldPresence({ input: 5 })).toBe(7);
  expect(bindgenCppInspectRest(1, "a", null, 3)).toBe(3);

  const input = new Uint8Array([3, 4, 5]);
  const output = bindgenCppEchoBuffer(input);
  expect([...output]).toEqual([3, 4, 5]);
  input[0] = 9;
  expect([...output]).toEqual([3, 4, 5]);
});

it("engine aggregate allocation failures propagate without partial results", () => {
  expect(withTransferFailures(() => bindgen.engineBufferSequenceLengthViaEngine())).toBe(5);
  expect(bindgen.engineBufferSequenceLengthViaEngine()).toBe(5);
});

it("schema C++ backends lazily convert values", () => {
  let conversions = 0;
  const input = {
    toString() {
      conversions++;
      return "lazy";
    },
  };

  expect(bindgenCppLazyStringLength(input, false)).toBe(0);
  expect(conversions).toBe(0);
  expect(bindgenCppLazyStringLength(input, true)).toBe(4);
  expect(conversions).toBe(1);
  const throwing = {
    toString() {
      throw new Error("lazy C++ conversion");
    },
  };
  expect(bindgenCppLazyStringLength(throwing, false)).toBe(0);
  expect(() => bindgenCppLazyStringLength(throwing, true)).toThrow("lazy C++ conversion");
});

it("schema engine shims map exceptions and transfer results", () => {
  const marker = { retained: true };
  let reads = 0;
  const target = {
    get 1() {
      reads++;
      return marker;
    },
    get 2() {
      throw new Error("engine getter failed");
    },
  };

  expect(bindgen.readIndexViaEngine(target, 1)).toBe(marker);
  expect(reads).toBe(1);
  expect(bindgen.nodePathLengthViaEngine("hello")).toBe(5);
  expect(() => bindgen.readIndexViaEngine(target, 2)).toThrow("engine getter failed");
  expect(() => bindgen.readIndexViaEngine(target, "1" as any)).toThrow();
});

it("string views and transfers", () => {
  expect(bindgen.domStringLength("latin1")).toBe(6);
  expect(bindgen.domStringLength("😀")).toBe(2);
  expect(bindgen.domStringLength({ toString: () => "coerced" })).toBe(7);

  expect(bindgen.echoDOMString("hello")).toBe("hello");
  expect(bindgen.echoDOMString("")).toBe("");
  expect(bindgen.echoDOMString("😀")).toBe("😀");
  expect(bindgen.echoDOMString("\ud800")).toBe("\ud800");
  expect(bindgen.echoUSVString("\ud800")).toBe("�");
  expect(bindgen.echoByteString("\xff")).toBe("\xff");
  expect(() => bindgen.echoByteString("Ā")).toThrow();

  expect(bindgen.strictUSVString("\ud800")).toBe("�");
  expect(bindgen.strictByteString("\xff")).toBe("\xff");
  try {
    bindgen.strictUSVString(42);
    throw new Error("expected strictUSVString to reject a non-string");
  } catch (error: any) {
    expect(error).toBeInstanceOf(TypeError);
    expect(error.code).toBeUndefined();
  }
  expect(() => bindgen.strictByteString({ toString: () => "coerced" })).toThrow();
  expect(() => bindgen.strictByteString("Ā")).toThrow();
});

it("realm-free string results isolate ownership and propagate allocation failure", async () => {
  for (const input of ["", "ascii", "café\0ÿ", "雪😀", "\ud800a\udc00"]) {
    expect(bindgen.isolateEngineString(input, false)).toBe(input);
    expect(() => bindgen.isolateEngineString(input, true)).toThrow(/memory/i);
    expect(bindgen.isolateEngineString(input, false)).toBe(input);
    expect(await bindgen.asyncWeakEcho(0, input)).toBe(input);
  }
});

it("copied buffer views and transfers", () => {
  const source = Uint8Array.from([10, 20, 30, 40]);
  const result = bindgen.echoBuffer(source.subarray(1, 3));
  expect(result).toBeInstanceOf(Uint8Array);
  expect([...result]).toEqual([20, 30]);
  expect(bindgen.echoBuffer(new Uint8Array())).toEqual(new Uint8Array());
  expect([...bindgen.echoBuffer(new DataView(Uint8Array.from([1, 2, 3]).buffer, 1, 2))]).toEqual([2, 3]);
  const shared = new Uint8Array(new SharedArrayBuffer(3));
  shared.set([4, 5, 6]);
  expect([...bindgen.echoBuffer(shared)]).toEqual([4, 5, 6]);
  const plain = Uint8Array.from([7, 8, 9]).buffer;
  expect([...bindgen.echoNullableBuffer(plain as any)!]).toEqual([7, 8, 9]);
  expect(() => bindgen.echoBuffer("not bytes")).toThrow();
});

it("engine byte leases pin backing stores and copy inline typed arrays", () => {
  expect(bindgen.inspectInt32FromJS(42)).toBe(42);
  expect(() => bindgen.inspectInt32FromJS(42.5)).toThrow(TypeError);
  expect(() => bindgen.inspectInt32FromJS("42")).toThrow(TypeError);

  const leased = new Uint8Array(64 * 1024);
  leased[0] = 5;
  leased[leased.length - 1] = 11;
  const inlineMutableLease = Uint8Array.from([1, 2, 3]);
  bindgen.fillMutableLease(inlineMutableLease, 9);
  expect([...inlineMutableLease]).toEqual([9, 9, 9]);

  const backedMutableLease = new Uint8Array(64 * 1024);
  bindgen.fillMutableLease(backedMutableLease.subarray(2, 5), 7);
  expect([...backedMutableLease.subarray(0, 7)]).toEqual([0, 0, 7, 7, 7, 0, 0]);

  const wasmMemory = new WebAssembly.Memory({ initial: 1 });
  const wasmMutableLease = new Uint8Array(wasmMemory.buffer, 4, 3);
  bindgen.fillMutableLease(wasmMutableLease, 6);
  expect([...wasmMutableLease]).toEqual([6, 6, 6]);

  wasmMutableLease.set([1, 2, 3]);
  bindgen.setMutableLeaseByte(
    wasmMutableLease,
    {
      valueOf() {
        wasmMutableLease.set([7, 8, 9]);
        return 0;
      },
    } as any,
    6,
  );
  expect([...wasmMutableLease]).toEqual([6, 8, 9]);

  wasmMutableLease.set([1, 2, 3]);
  const conversionError = new Error("conversion failed");
  expect(() =>
    bindgen.setMutableLeaseByte(
      wasmMutableLease,
      {
        valueOf() {
          wasmMutableLease.set([4, 5, 6]);
          throw conversionError;
        },
      } as any,
      9,
    ),
  ).toThrow(conversionError);
  expect([...wasmMutableLease]).toEqual([4, 5, 6]);

  expect(
    bindgen.inspectLeaseAfterCallback(leased, length => {
      expect(length).toBe(leased.length);
      expect(() => leased.buffer.transfer()).toThrow(TypeError);
      expect(() => leased.buffer.transferToFixedLength()).toThrow(TypeError);
      const earlier = Uint8Array.from([1, 2, 3]).buffer;
      let error: unknown;
      try {
        structuredClone({ earlier, leased: leased.buffer }, { transfer: [earlier, leased.buffer] });
      } catch (caught) {
        error = caught;
      }
      expect(error).toBeInstanceOf(DOMException);
      expect((error as DOMException).name).toBe("DataCloneError");
      expect(earlier.byteLength).toBe(3);
      expect(leased.byteLength).toBe(64 * 1024);
    }),
  ).toBe(5 * 256 + 11);
  expect(
    bindgen.inspectNestedLeaseAfterCallback(leased, length => {
      expect(length).toBe(leased.length);
      expect(() => leased.buffer.transfer()).toThrow(TypeError);
      expect(() => leased.buffer.transferToFixedLength()).toThrow(TypeError);
      let error: unknown;
      try {
        structuredClone(leased.buffer, { transfer: [leased.buffer] });
      } catch (caught) {
        error = caught;
      }
      expect(error).toBeInstanceOf(DOMException);
      expect((error as DOMException).name).toBe("DataCloneError");
    }),
  ).toBe(5 * 256 + 11);
  expect(bindgen.inspectNestedLeaseAfterCallback("lease", length => expect(length).toBe(5))).toBe(5);

  expect(
    bindgen.invokeTypedRestCallback((prefix, ...values) => prefix + values.reduce((a, b) => a + b, 0), 10, 1, 2, 3),
  ).toBe(16);
  expect(() => (bindgen.invokeTypedRestCallback as any)(() => 0, 10, 1, "2")).toThrow(TypeError);
  expect(bindgen.inspectCustomConverters([1, 2, 3], "z", "x", "y")).toBe(60_000 + 10_000 + 800 + 8);
  expect(bindgen.inspectCustomConverters([1, 2, 3], null)).toBe(60_000 + 8);
  let lazyCountRead = false;
  const lazyOptions = {
    get count() {
      lazyCountRead = true;
      throw new Error("lazy count read");
    },
    metadata: { mode: "fast" as const },
  };
  expect(bindgen.inspectLazyOptions(lazyOptions, false)).toBe(-1);
  expect(lazyCountRead).toBe(false);
  expect(() => bindgen.inspectLazyOptions(lazyOptions, true)).toThrow("lazy count read");
  expect(lazyCountRead).toBe(true);
  expect(bindgen.inspectLazyOptions({ count: 7, label: "abc", metadata: { mode: "fast" } }, true)).toBe(10);
  expect(bindgen.inspectLazyConvertedLabel("abc")).toBe("custom:abc".length);
  expect(bindgenCppCallZigNativeString("native", Uint8Array.of(1, 2))).toBe("native");

  const convertedLease = Uint8Array.from([3, 9]);
  expect(bindgen.inspectLeaseOptionsFromJS({ bytes: convertedLease, marker: null })).toBe(3 * 256 + 9);
  const invalidatedLease = new Uint8Array(64 * 1024);
  invalidatedLease[0] = 4;
  invalidatedLease[invalidatedLease.length - 1] = 7;
  expect(() =>
    bindgen.inspectLeaseOptionsFromJS({
      bytes: invalidatedLease,
      get marker() {
        invalidatedLease.buffer.transfer();
        return null;
      },
    }),
  ).toThrow(TypeError);

  leased.buffer.transfer();
  expect(leased.byteLength).toBe(0);

  const inline = Uint8Array.of(9, 4);
  let transferred: ArrayBuffer | undefined;
  expect(
    bindgen.inspectLeaseAfterCallback(inline, () => {
      transferred = inline.buffer.transfer();
    }),
  ).toBe(9 * 256 + 4);
  expect([...new Uint8Array(transferred!)]).toEqual([9, 4]);
  expect(inline.byteLength).toBe(0);
});

it.each([false, true])("snapshots inline byte leases after later property access (materialize: %s)", materialize => {
  const bytes = Uint8Array.of(1, 2);
  expect(
    bindgen.inspectLeaseOptionsFromJS({
      bytes,
      get marker() {
        bytes[0] = 7;
        if (materialize) void bytes.buffer;
        Bun.gc(true);
        return "converted";
      },
    }),
  ).toBe(7 * 256 + 2);
});

it("WebAssembly growth preserves active byte-lease copies", () => {
  for (const growth of [0, 1]) {
    for (const offsetView of [false, true]) {
      const memory = new WebAssembly.Memory({ initial: 1, maximum: 2 });
      const backing = memory.buffer;
      const offset = offsetView ? 7 : 0;
      const length = offsetView ? 16 : backing.byteLength;
      const bytes = new Uint8Array(backing, offset, length);
      bytes[0] = 7;
      bytes[length - 1] = 13;
      const input = offsetView ? bytes : backing;

      expect(
        bindgen.inspectLeaseAfterCallback(input as any, observedLength => {
          expect(observedLength).toBe(length);
          expect(memory.grow(growth)).toBe(1);
          expect(backing.byteLength).toBe(0);
          const current = new Uint8Array(memory.buffer);
          current[offset] = 99;
          current[offset + length - 1] = 88;
          Bun.gc(true);
        }),
      ).toBe(7 * 256 + 13);
    }
  }
});

it("engine byte leases defer resizable ArrayBuffer tail decommit", () => {
  const backing = new ArrayBuffer(8192, { maxByteLength: 16384 });
  const view = new Uint8Array(backing);
  view[0] = 7;
  view[view.length - 1] = 13;

  expect(
    bindgen.inspectLeaseAfterCallback(view, length => {
      expect(length).toBe(8192);
      backing.resize(1);
      expect(backing.byteLength).toBe(1);
    }),
  ).toBe(7 * 256 + 13);

  backing.resize(8192);
  expect(new Uint8Array(backing)[8191]).toBe(0);
  backing.transfer();
  expect(backing.byteLength).toBe(0);
});

it("rooted JS value transfers", () => {
  const object = { retained: true };
  expect(bindgen.echoAny(object)).toBe(object);
  expect(bindgen.echoAny(undefined)).toBeUndefined();
  expect(bindgen.echoAny(null)).toBeNull();
  expect(bindgen.echoAny(42)).toBe(42);

  const receiver = {};
  expect(bindgen.invocationThis.call(receiver)).toBe(receiver);
});

it("transferred engine dictionaries release only their own root clone", () => {
  const object = { retained: true };
  let collected = false;
  const result = bindgen.preserveTransferredRoot(object, () => {
    Bun.gc(true);
    collected = true;
  });
  expect(collected).toBe(true);
  expect(result).toBe(object);
  expect(result.retained).toBe(true);
});

it.each([undefined, null, 42, { retained: true }])(
  "stored root views survive clearing, reuse, release, and GC: %p",
  input => {
    const replacement = { replacement: true };
    const engine = Symbol("engine");
    const promise = Promise.resolve(input);
    const result = bindgen.snapshotStoredRoots(input, replacement, engine, promise, () => Bun.gc(true));
    expect(result.root).toBe(input);
    expect(result.optional).toBe(input);
    expect(result.engine).toBe(engine);
    expect(result.promise).toBe(promise);
    expect(result.replacement).toBe(replacement);
    expect(result.cleared).toBe(true);
    expect(result.reused).toBe(true);
  },
);

it.each(["snapshot", "root"] as const)("allocation failures unwind stored %s values", kind => {
  const input = { retained: true };
  const replacement = { replacement: true };
  const engine = Symbol("engine");
  const promise = Promise.resolve(input);
  let collections = 0;
  const collect = () => {
    collections++;
    Bun.gc(true);
  };
  for (let failAfter = 0; failAfter < (kind === "snapshot" ? 6 : 8); failAfter++) {
    expect(() => {
      if (kind === "snapshot") {
        bindgen.snapshotStoredRoots(input, replacement, engine, promise, collect, failAfter);
      } else {
        bindgen.setRootAllocationFailureCountdown(failAfter);
        try {
          bindgen.snapshotStoredRoots(input, replacement, engine, promise, collect);
        } finally {
          bindgen.setRootAllocationFailureCountdown(-1);
        }
      }
    }).toThrow("Out of memory");
    expect(collections).toBe(0);
  }
  expect(bindgen.snapshotStoredRoots(input, replacement, engine, promise, collect)).toEqual({
    root: input,
    optional: input,
    engine,
    promise,
    replacement,
    cleared: true,
    reused: true,
  });
  expect(collections).toBe(1);
});

it("native record results retain callbacks and byte ownership across collection", () => {
  const input = Uint8Array.of(3, 5, 8);
  const create = () => {
    let index = 0;
    return bindgenCppCallZigNativeRecord(() => {
      const state = { index: ++index };
      return () => state.index;
    }, input);
  };
  const result = withTransferFailures(create);
  expect(Object.keys(result)).toEqual(["first", "second"]);
  expect(result.first.callback()).toBe(1);
  expect(result.second.callback()).toBe(2);
  input[0] = 99;
  expect([...result.first.bytes]).toEqual([3, 5, 8]);
  result.first.bytes[0] = 7;
  expect([...result.second.bytes]).toEqual([3, 5, 8]);

  let failures = 0;
  for (let failAfter = 0; failAfter < 16; failAfter++) {
    let caught: unknown;
    try {
      bindgen.setRootAllocationFailureCountdown(failAfter);
      create();
    } catch (error) {
      caught = error;
    } finally {
      bindgen.setRootAllocationFailureCountdown(-1);
    }
    if (caught === undefined) break;
    expect((caught as Error).message).toBe("Out of memory");
    failures++;
  }
  expect(failures).toBeGreaterThan(0);

  let attempts = 0;
  expect(() =>
    bindgenCppCallZigNativeRecord(() => {
      if (++attempts === 2) throw new Error("record factory failed");
      return () => 42;
    }, input),
  ).toThrow("record factory failed");
  const recovered = create();
  expect(recovered.first.callback()).toBe(1);
  expect(recovered.second.callback()).toBe(2);
  expect([...recovered.second.bytes]).toEqual([...input]);
});

it("scopes callback record views and retains them explicitly", () => {
  const create = () => ({
    first: {
      callback: () => {
        Bun.gc(true);
        return 11;
      },
      bytes: Uint8Array.of(3),
    },
    second: {
      callback: () => {
        Bun.gc(true);
        return 13;
      },
      bytes: Uint8Array.of(5),
    },
  });
  expect(bindgen.inspectCallbackRecordViews(create)).toBe(24);
  const retained = bindgen.retainCallbackRecord(create);
  Bun.gc(true);
  expect(retained.first.callback()).toBe(11);
  expect(retained.second.callback()).toBe(13);
  expect([...retained.first.bytes]).toEqual([3]);
  expect([...retained.second.bytes]).toEqual([5]);
  expect(bindgen.inspectCallbackRecordViews(() => ({}), 0)).toBe(0);

  let failures = 0;
  let succeeded = false;
  for (let failAfter = 0; failAfter < 16; failAfter++) {
    try {
      expect(bindgen.inspectCallbackRecordViews(create, failAfter)).toBe(24);
      succeeded = true;
      break;
    } catch (error) {
      expect((error as Error).message).toBe("Out of memory");
      failures++;
    }
  }
  expect(failures).toBeGreaterThan(0);
  expect(succeeded).toBe(true);
  expect(() =>
    bindgen.inspectCallbackRecordViews(() => ({
      ...create(),
      first: {
        callback: () => {
          throw new Error("view failed");
        },
        bytes: Uint8Array.of(7),
      },
    })),
  ).toThrow("view failed");
  Bun.gc(true);
  expect(bindgen.inspectCallbackRecordViews(create)).toBe(24);
});

it("root allocation failures unwind composite callback result transfers", () => {
  const choice = new bindgen.Counter(7);
  const input = {
    choice,
    labels: ["first", "second"],
    value: { retained: true },
    observer() {},
    label: "complete",
  };
  let failures = 0;
  for (let failAfter = 0; failAfter < 16; failAfter++) {
    let caught: unknown;
    try {
      bindgen.invokeCompositeCallback(() => {
        bindgen.setRootAllocationFailureCountdown(failAfter);
        return input;
      });
    } catch (error) {
      caught = error;
    } finally {
      bindgen.setRootAllocationFailureCountdown(-1);
    }
    if (caught === undefined) break;
    expect((caught as Error).message).toBe("Out of memory");
    failures++;
  }
  expect(failures).toBeGreaterThan(0);
  Bun.gc(true);
  const result = bindgen.invokeCompositeCallback(() => input);
  expect(result.choice).toBe(choice);
  expect(result.observer).toBe(input.observer);
});

it.each([
  ["visitGCEntries", 1],
  ["visitDeferredGCEntries", 2],
] as const)("roots values in aggregate converter storage across later coercion: %s", (method, visits) => {
  let getters = 0;
  let callbacks = 0;
  const entries = Array.from({ length: 32 }, (_, index) => ({
    get value() {
      getters++;
      return { index: index + 1 };
    },
    get callback() {
      getters++;
      return (value: unknown) => {
        callbacks++;
        if (callbacks === 1) Bun.gc(true);
        return (value as { index: number }).index;
      };
    },
    get bytes() {
      getters++;
      const bytes = new Uint8Array(new ArrayBuffer(32));
      bytes[0] = index + 1;
      return bytes;
    },
  }));
  const trigger = {
    [Symbol.toPrimitive]() {
      entries.length = 0;
      for (let index = 0; index < 3; index++) Bun.gc(true);
      return "converted";
    },
  };
  const ignored = {
    [Symbol.toPrimitive]() {
      throw new Error("ignored operand was converted");
    },
  };
  expect(
    method === "visitDeferredGCEntries"
      ? bindgen.visitDeferredGCEntries(entries, trigger, ignored)
      : bindgen.visitGCEntries(entries, trigger),
  ).toBe(1056 * visits);
  expect(getters).toBe(96);
  expect(callbacks).toBe(32 * visits);
});

it("closes an ignored deferred operand before acquiring a lease", () => {
  expect(
    bindgen.leaseWithIgnoredOperand(Uint8Array.of(73), {
      [Symbol.toPrimitive]() {
        throw new Error("ignored operand was converted");
      },
    }),
  ).toBe(73);
});

it("forwarded lazy values complete once before the final lease proof", () => {
  const input = Uint8Array.of(73);
  let conversions = 0;
  expect(
    bindgen.leaseWithIgnoredOperand(
      input,
      {
        toString() {
          throw new Error("ignored operand was converted");
        },
      },
      {
        toString() {
          conversions++;
          input[0] = 91;
          Bun.gc(true);
          return "converted";
        },
      },
    ),
  ).toBe(91);
  expect(conversions).toBe(1);
});

it.each(["retryLazyString", "retryCppLazyString"] as const)(
  "caches deferred conversion values and restores cached exceptions: %s",
  method => {
    let conversions = 0;
    const input = {
      toString() {
        conversions++;
        return "deferred";
      },
    };
    expect(bindgen[method](input)).toBe(16);
    expect(conversions).toBe(1);

    const sentinel = new Error("deferred failure");
    conversions = 0;
    expect(() =>
      bindgen[method]({
        toString() {
          conversions++;
          throw sentinel;
        },
      }),
    ).toThrow(sentinel);
    expect(conversions).toBe(1);
  },
);

it("captures callback context and preserves identity across eager and deferred conversion", () => {
  const storage = new AsyncLocalStorage<number>();
  const observed: (number | undefined)[] = [];
  const callback = () => observed.push(storage.getStore());
  storage.run(1, () => {
    expect(bindgen.callbackIdentityAfterReentry(callback, callback, () => storage.enterWith(2))).toBe(true);
    expect(storage.getStore()).toBe(2);
    expect(observed).toEqual([1, 2]);
    expect(
      bindgen.callbackIdentityAfterReentry(
        callback,
        () => {},
        () => storage.enterWith(3),
      ),
    ).toBe(false);
  });
});

it("cached callbacks preserve context and identity without temporary roots", () => {
  const storage = new AsyncLocalStorage<number>();
  const counter = new bindgen.Counter();
  const observed: (number | undefined)[] = [];
  const callback = () => observed.push(storage.getStore());
  expect(counter.cachedCallback).toBeUndefined();
  for (const useMethod of [false, true]) {
    storage.run(1, () => {
      bindgen.setRootAllocationFailureCountdown(0);
      try {
        if (useMethod) counter.setCachedCallback(callback);
        else counter.cachedCallback = callback;
      } finally {
        bindgen.setRootAllocationFailureCountdown(-1);
      }
    });
    Bun.gc(true);
    storage.run(2, () => {
      expect(counter.cachedCallback).toBe(callback);
      counter.invokeCachedCallback();
      counter.cachedCallback!();
    });
  }
  expect(observed).toEqual([1, 2, 1, 2]);
});

it("typed callback invocation and rooting", () => {
  const reducer = function (this: undefined, value: number, label: string) {
    expect(this).toBeUndefined();
    expect(label).toBe("callback 😀");
    return bindgen.add(value, label.length);
  };
  expect(bindgen.invokeCallback(reducer, 7, "callback 😀")).toBe(18);
  expect(bindgen.invokeOwnedCallback(reducer, 9, "callback 😀")).toBe(20);
  expect(bindgen.echoCallback(reducer)).toBe(reducer);

  expect(() => bindgen.invokeCallback(42 as any, 1, "unused")).toThrow("callback must be callable");

  const sentinel = new Error("callback sentinel");
  try {
    bindgen.invokeCallback(
      () => {
        throw sentinel;
      },
      1,
      "unused",
    );
    throw new Error("expected callback exception");
  } catch (error) {
    expect(error).toBe(sentinel);
  }

  try {
    bindgen.invokeCallback(() => "not an integer" as any, 1, "unused");
    throw new Error("expected callback result conversion to fail");
  } catch (error: any) {
    expect(error).toBeInstanceOf(TypeError);
    expect(error.code).toBeUndefined();
  }

  expect(bindgen.invokeStringCallback(input => input + "\ud800", "string 😀")).toBe("string 😀�");
  expect(() => bindgen.invokeStringCallback(() => 42 as any, "unused")).toThrow();

  const bytes = Uint8Array.from([1, 2, 3]);
  const mappedBytes = bindgen.invokeBufferCallback(input => {
    expect(Buffer.isBuffer(input)).toBe(true);
    expect([...input]).toEqual([1, 2, 3]);
    return Uint8Array.from([input[2], input[0]]);
  }, bytes);
  expect([...mappedBytes]).toEqual([3, 1]);
  expect([...bindgen.invokeBufferCallback(() => Uint8Array.from([8, 5]).buffer as any, bytes)]).toEqual([8, 5]);
  expect([...bytes]).toEqual([1, 2, 3]);
  expect(() => bindgen.invokeBufferCallback(() => "not bytes" as any, bytes)).toThrow();

  const inputValue = { input: true };
  const outputValue = { output: true };
  expect(
    bindgen.invokeAnyCallback(value => {
      expect(value).toBe(inputValue);
      return outputValue;
    }, inputValue),
  ).toBe(outputValue);

  const restValues = Array.from({ length: 10 }, (_, index) => ({ index }));
  const restCallback = (prefix: number, ...values: unknown[]) => {
    expect(values).toEqual(restValues.slice(0, values.length));
    return prefix + values.length;
  };
  expect(bindgen.invokeRestCallback(restCallback, 40)).toBe(40);
  expect(bindgen.invokeRestCallback(restCallback, 40, ...restValues.slice(0, 3))).toBe(43);
  expect(bindgen.invokeRestCallback(restCallback, 40, ...restValues)).toBe(50);

  expect(bindgen.invokeCallbackFactory(() => (value, label) => value + label.length, 5, "factory")).toBe(12);
  expect(() => bindgen.invokeCallbackFactory(() => 42 as any, 1, "unused")).toThrow();

  let observed = 0;
  expect(
    bindgen.invokeObserver(value => {
      observed = value;
      return "ignored";
    }, 91),
  ).toBeUndefined();
  expect(observed).toBe(91);
});

it("scheduled callbacks preserve receiver, arguments, and async context", async () => {
  const storage = new AsyncLocalStorage<string>();
  let called = false;
  await new Promise<void>((resolve, reject) => {
    let receiver: { name: string } | null = { name: "receiver" };
    let value: { name: string } | null = { name: "argument" };
    const weakReceiver = new WeakRef(receiver);
    const weakValue = new WeakRef(value);
    storage.run("scheduled context", () => {
      bindgen.scheduleCallback(
        function (this: { name: string }, argument: { name: string }) {
          try {
            called = true;
            expect(this).toBe(weakReceiver.deref());
            expect(this.name).toBe("receiver");
            expect(argument).toBe(weakValue.deref());
            expect(argument.name).toBe("argument");
            expect(storage.getStore()).toBe("scheduled context");
            resolve();
          } catch (error) {
            reject(error);
          }
        },
        receiver,
        value,
      );
    });
    receiver = null;
    value = null;
    Bun.gc(true);
    expect(called).toBe(false);
  });
  expect(called).toBe(true);
});

it("converts callback composites once and preserves their owned identities", () => {
  const reads: string[] = [];
  let observed = 0;
  const choice = new bindgen.Counter(7);
  const observer = () => observed++;
  const input = () => ({
    get choice() {
      reads.push("choice");
      return choice;
    },
    get labels() {
      reads.push("labels");
      return ["first", "second 😀"];
    },
    get value() {
      reads.push("value");
      return { retained: true };
    },
    get observer() {
      reads.push("observer");
      return observer;
    },
    get label() {
      reads.push("label");
      Bun.gc(true);
      return "complete";
    },
  });
  const result = bindgen.invokeCompositeCallback(input);
  expect(reads).toEqual(["choice", "labels", "value", "observer", "label"]);
  expect(result.choice).toBe(choice);
  expect(result.labels).toEqual(["first", "second 😀"]);
  expect(result.value).toEqual({ retained: true });
  expect(result.observer).toBe(observer);
  result.observer();
  expect(observed).toBe(1);
  expect(result.label).toBe("complete");

  reads.length = 0;
  expect(() => bindgen.invokeCompositeCallback(() => ({ ...input(), choice: {} as any }))).toThrow(TypeError);

  expect(withTransferFailures(() => bindgen.invokeCompositeCallback(input)).choice).toBe(choice);
});

it("preserves captured dictionary sources through shared conversion", () => {
  expect(bindgen.echoDictionarySource(undefined)).toBeUndefined();
  expect(bindgen.echoDictionarySource(null)).toBeNull();
  let reads = 0;
  const input = {
    get trigger() {
      reads++;
      Bun.gc(true);
      return "converted";
    },
  };
  expect(bindgen.echoDictionarySource(input)).toBe(input);
  expect(reads).toBe(1);
});

it("clamped and Node integer conversions", () => {
  expect(bindgen.clampInteger(-20)).toBe(-10);
  expect(bindgen.clampInteger(20)).toBe(10);
  expect(bindgen.clampInteger(2.5)).toBe(2);
  expect(bindgen.clampInteger(3.5)).toBe(4);
  expect(bindgen.clampInteger(NaN)).toBe(0);
  expect(bindgen.clampInteger("7")).toBe(7);

  expect(bindgen.validateInteger(42)).toBe(42);
  for (const [value, received] of [
    ["42", "type string ('42')"],
    [1n, "type bigint (1n)"],
  ] as const) {
    try {
      bindgen.validateInteger(value);
      throw new Error("expected validateInteger to reject a non-number");
    } catch (error: any) {
      expect(error).toBeInstanceOf(TypeError);
      expect(error.code).toBe("ERR_INVALID_ARG_TYPE");
      expect(error.message).toBe(`The "input" argument must be of type number. Received ${received}`);
    }
  }
  for (const [value, requirement] of [
    [1.5, "an integer"],
    [-1, ">= 0 && <= 100"],
    [101, ">= 0 && <= 100"],
  ] as const) {
    try {
      bindgen.validateInteger(value);
      throw new Error("expected validateInteger to reject an out-of-range value");
    } catch (error: any) {
      expect(error).toBeInstanceOf(RangeError);
      expect(error.code).toBe("ERR_OUT_OF_RANGE");
      expect(error.message).toBe(`The value of "input" is out of range. It must be ${requirement}. Received ${value}`);
    }
  }
});

it("Node conversion profiles validate scalars and nested array elements", () => {
  const expectInvalidArgument = (callback: () => unknown, message: string) => {
    try {
      callback();
      throw new Error("expected Node conversion to reject the value");
    } catch (error: any) {
      expect(error).toBeInstanceOf(TypeError);
      expect(error.code).toBe("ERR_INVALID_ARG_TYPE");
      expect(error.message).toBe(message);
    }
  };

  expect(bindgen.validateNodeBoolean(true)).toBeTrue();
  expect(bindgen.validateNodeNumber(1.25)).toBe(1.25);
  expect(bindgen.validateNodeString("hello")).toBe(5);
  expect(bindgen.validateNodeStrings(["one", "two"])).toBe(2);

  expectInvalidArgument(
    () => bindgen.validateNodeBoolean(1 as any),
    'The "input" argument must be of type boolean. Received type number (1)',
  );
  expectInvalidArgument(
    () => bindgen.validateNodeNumber("1.25" as any),
    "The \"input\" argument must be of type number. Received type string ('1.25')",
  );
  expectInvalidArgument(
    () => bindgen.validateNodeString({ toString: () => "hello" } as any),
    'The "input" argument must be of type string. Received an instance of Object',
  );
  expectInvalidArgument(
    () => bindgen.validateNodeStrings(new Set(["one"]) as any),
    'The "input" argument must be of type Array. Received an instance of Set',
  );
  expectInvalidArgument(
    () => bindgen.validateNodeStrings(["one", 2] as any),
    'The "element of input" argument must be of type string. Received type number (2)',
  );
});

it("iterable selection retains the method through overloads, engine forwarding, lazy conversion, GC, and reentry", () => {
  const events: string[] = [];
  const input = {
    get [Symbol.iterator]() {
      events.push("get iterator");
      if (events.filter(event => event === "get iterator").length > 1) throw new Error("iterator read twice");
      return function* () {
        expect(this).toBe(input);
        events.push("iterate");
        yield 1;
        yield 2;
      };
    },
  };
  expect(
    bindgen.dispatchAdvanced(input, "x", () => {
      events.push("callback");
      expect(bindgen.dispatchAdvanced(new Set([3]), "x")).toBe(108);
      Bun.gc(true);
    }),
  ).toBe(208);
  expect(events).toEqual(["get iterator", "callback", "iterate"]);

  const failure = new Error("iterator getter failed");
  const invalid = {
    get [Symbol.iterator]() {
      throw failure;
    },
    get count() {
      throw new Error("fallback conversion ran");
    },
  };
  expect(() => bindgen.dispatchAdvanced(invalid as any, "x")).toThrow(failure);
});

it.each(["inspectNestedLazyFields", "inspectEagerLazyFields"] as const)(
  "forces nested lazy fields once before leasing: %s",
  method => {
    const events: string[] = [];
    const bytes = Uint8Array.of(73);
    const input = {
      get options() {
        events.push("options");
        return {
          get items() {
            events.push("items");
            return {
              get [Symbol.iterator]() {
                events.push("iterator");
                return function* () {
                  yield 1;
                  yield 2;
                };
              },
            };
          },
          get label() {
            events.push("label");
            return {
              toString() {
                events.push("coerce");
                bytes[0] = 91;
                Bun.gc(true);
                return "ok";
              },
            };
          },
          get ignored() {
            throw new Error("discarded field getter ran");
          },
        };
      },
    };
    const result =
      method === "inspectNestedLazyFields"
        ? bindgen.inspectNestedLazyFields(input, bytes, () => events.push("trigger"))
        : bindgen.inspectEagerLazyFields(input, bytes);
    expect(result).toBe(96);
    expect(events).toEqual([
      ...(method === "inspectNestedLazyFields" ? ["trigger"] : []),
      "options",
      "items",
      "iterator",
      "label",
      "coerce",
    ]);

    const sentinel = new Error("nested field getter failed");
    let reads = 0;
    const invalid = {
      options: {
        items: [1],
        get label() {
          reads++;
          throw sentinel;
        },
      },
    };
    let caught: unknown;
    try {
      if (method === "inspectNestedLazyFields") bindgen.inspectNestedLazyFields(invalid, bytes, () => {});
      else bindgen.inspectEagerLazyFields(invalid, bytes);
    } catch (error) {
      caught = error;
    }
    expect(caught).toBe(sentinel);
    expect(reads).toBe(1);
  },
);

it("lazy conversion retains its receiver and validates it after reentry", () => {
  expect(bindgen.inspectLazyReceiverIndex.call(new Uint8Array(8), 5, () => Bun.gc(true))).toBe(5);
  const buffer = new ArrayBuffer(8, { maxByteLength: 16 });
  const receiver = new Uint8Array(buffer);
  expect(() =>
    bindgen.inspectLazyReceiverIndex.call(receiver, 5, () => {
      buffer.resize(2);
      Bun.gc(true);
    }),
  ).toThrow(RangeError);
});

it("lazy rest preparation registers every deferred value before acquiring leases", () => {
  const bytes = Uint8Array.of(7);
  let reads = 0;
  const value = {
    toString() {
      reads++;
      Bun.gc(true);
      return "abc";
    },
  };
  const ignored = {
    toString() {
      throw new Error("discarded rest value was converted");
    },
  };
  expect(bindgen.inspectLazyRestLease(bytes, () => Bun.gc(true), true, value, ignored)).toBe(10);
  expect(reads).toBe(1);
  expect(bindgen.inspectLazyRestLease(bytes, () => Bun.gc(true), false, value, "xy")).toBe(12);
  expect(reads).toBe(2);
  expect(bindgen.inspectLazyRestLease(bytes, () => {}, false)).toBe(7);
});

it("typed rest arguments preserve brands and C++ conversion storage", () => {
  expect(bindgen.inspectBrandedRest()).toBe(0);
  expect(bindgen.inspectBrandedRest([], [1])).toBe(2);
  expect(() => bindgen.inspectBrandedRest([], {})).toThrow(TypeError);
  let reads = 0;
  expect(
    bindgen.cppInspectStringRest("abc", {
      toString() {
        reads++;
        Bun.gc(true);
        return "de";
      },
    }),
  ).toBe(5);
  expect(reads).toBe(1);
  expect(bindgen.cppInspectStringRest()).toBe(0);
});

it("lazy rest values expose nested deferred fields", () => {
  let reads = 0;
  const make = (items: number[], label: string) => ({
    get options() {
      reads++;
      Bun.gc(true);
      return {
        items,
        label,
        get ignored() {
          throw new Error("unused rest field getter ran");
        },
      };
    },
  });
  expect(bindgen.inspectNestedLazyRest(make([1], "a"), make([2, 3], "bc"))).toBe(9);
  expect(reads).toBe(2);
});

it("lazy field diagnostics keep only their own path context", () => {
  const options = { relative: { text: 42 }, absolute: { text: 42 } } as any;
  expect(bindgen.forceLazyPath({ relative: { text: "abc" }, absolute: {} } as any, false)).toBe(3);
  expect(() => bindgen.forceLazyPath(options, false)).toThrow(/^options\.relative\.text must be a string/);
  expect(() => bindgen.forceLazyPath(options, true)).toThrow(/^fixed\.absolute\.text must be a string/);
});

it("sequence element patterns select only the outer union member", () => {
  expect(bindgen.describePatternValues([true, "abc", false, 7])).toBe("flag:true text:3 flag:false number:7");
  expect(() => bindgen.describePatternValues([true])).toThrow("Expected flag and value pairs");
});

it("Node conversion preserves overload, field, and alias order", () => {
  for (const [hostname, port, expected, order] of [
    [undefined, 9, 16, ["hostname", "host", "port"]],
    ["primary", 4, 11, ["hostname", "port"]],
    [42, 4, null, ["hostname"]],
  ] as const) {
    const accesses: string[] = [];
    const input = {
      get hostname() {
        accesses.push("hostname");
        return hostname as any;
      },
      get host() {
        accesses.push("host");
        return "example";
      },
      get port() {
        accesses.push("port");
        return port;
      },
    };
    if (expected === null) {
      expect(() => bindgen.inspectNodeConversionOrder(input)).toThrow(
        'The "input.hostname" property must be of type string',
      );
    } else {
      expect(bindgen.inspectNodeConversionOrder(input)).toBe(expected);
    }
    expect(accesses).toEqual(order);
  }
  expect(bindgen.inspectNodeConversionOrder("fallback")).toBe(-1);
});

it("schema defaults for strings and raw values", () => {
  expect(bindgen.defaultString()).toBe("default 😀");
  expect(bindgen.defaultString(undefined)).toBe("default 😀");
  expect(bindgen.defaultString("explicit")).toBe("explicit");
  expect(() => bindgen.defaultString(null)).toThrow();

  expect(bindgen.defaultAny()).toBeNull();
  expect(bindgen.defaultAny(undefined)).toBeNull();
  const explicit = { explicit: true };
  expect(bindgen.defaultAny(explicit)).toBe(explicit);
});

it("schema distinguishes omitted, undefined, and null arguments", () => {
  expect(bindgen.classifyPresence()).toBe("missing");
  expect(bindgen.classifyPresence(undefined)).toBe("undefined");
  expect(bindgen.classifyPresence(null)).toBe("null");
  expect(bindgen.classifyPresence(false)).toBe("value");
});

it("schema exposes call-scoped rest argument views", () => {
  expect(bindgen.inspectRest(7)).toBe(7);
  expect(bindgen.inspectRest(7, undefined, null, true)).toBe(3118);
  expect(bindgen.inspectStringRest("ab", "cde")).toBe(5);
  expect(() => bindgen.inspectStringRest("ok", 42 as any)).toThrow("values[1] must be a string");
});

it("typed string rest conversion preserves order and stops at the first exception", () => {
  expect(bindgen.echoStringRest()).toEqual([]);
  const seen: number[] = [];
  const values = Array.from({ length: 32 }, (_, index) => ({
    toString() {
      seen.push(index);
      Bun.gc(true);
      return `value ${index} 😀`;
    },
  }));
  expect(bindgen.echoStringRest(null, "", ...values)).toEqual([
    null,
    "",
    ...values.map((_, index) => `value ${index} 😀`),
  ]);
  expect(seen).toEqual(values.map((_, index) => index));

  const failure = new Error("rest conversion failed");
  seen.length = 0;
  let caught: unknown;
  try {
    bindgen.echoStringRest(
      values[0],
      {
        toString() {
          throw failure;
        },
      },
      values[1],
    );
  } catch (error) {
    caught = error;
  }
  expect(caught).toBe(failure);
  expect(seen).toEqual([0]);
  expect(bindgen.echoStringRest("after failure", null)).toEqual(["after failure", null]);
});

it("typed buffer rest values keep their copies across callback reentry", () => {
  const source = new Uint8Array([99, 1, 2, 3, 99]);
  const other = new Uint8Array([4, 5]);
  const output = bindgen.echoBufferRest(
    () => {
      source.fill(0);
      structuredClone(other.buffer, { transfer: [other.buffer] });
      Bun.gc(true);
    },
    new DataView(source.buffer, 1, 3),
    null,
    new Uint8Array(),
    other,
  );
  expect(output.map(value => (value === null ? null : [...value]))).toEqual([[1, 2, 3], null, [], [4, 5]]);
  let dispatched = false;
  expect(() => bindgen.echoBufferRest(() => (dispatched = true), source, {} as any)).toThrow(TypeError);
  expect(dispatched).toBe(false);
  expect(bindgen.echoBufferRest(() => {})).toEqual([]);
});

it("typed aggregate rest values retain dictionary and union conversions", () => {
  const seen: string[] = [];
  const values = Array.from({ length: 24 }, (_, index) => ({
    get label() {
      seen.push(`label ${index}`);
      return `entry ${index}`;
    },
    get value() {
      seen.push(`value ${index}`);
      Bun.gc(true);
      return index % 3 === 0 ? index : index % 3 === 1 ? `text ${index}` : false;
    },
  }));
  expect(bindgen.echoAggregateRest(...values)).toEqual(
    values.map((_, index) => ({
      label: `entry ${index}`,
      value: index % 3 === 0 ? index : index % 3 === 1 ? `text ${index}` : false,
    })),
  );
  expect(seen).toEqual(values.flatMap((_, index) => [`label ${index}`, `value ${index}`]));
  expect(bindgen.echoAggregateRest()).toEqual([]);
  expect(() => bindgen.echoAggregateRest({ label: "bad", value: {} as any })).toThrow(TypeError);
});

it("schema optional values preserve null independently of child values", () => {
  expect(bindgen.echoNullableInt(null)).toBeNull();
  expect(bindgen.echoNullableInt(42)).toBe(42);
  expect(() => bindgen.echoNullableInt(undefined as any)).toThrow(TypeError);
  expect(bindgen.classifyNullablePresence()).toBe(0);
  expect(bindgen.classifyNullablePresence(null)).toBe(1);
  expect(bindgen.classifyNullablePresence(40)).toBe(42);
  expect(() => bindgen.classifyNullablePresence(undefined)).toThrow(TypeError);

  expect(bindgen.echoNullableString(null)).toBeNull();
  expect(bindgen.echoNullableString("nullable")).toBe("nullable");
  expect(() => bindgen.echoNullableString(undefined as any)).toThrow(TypeError);

  expect(bindgen.echoNullableAny(null)).toBeNull();
  expect(bindgen.echoNullableAny(undefined)).toBeUndefined();
  const value = { nullable: true };
  expect(bindgen.echoNullableAny(value)).toBe(value);

  expect(bindgen.invokeNullableStringCallback(input => (input === null ? "from null" : null), null)).toBe("from null");
  expect(bindgen.invokeNullableStringCallback(() => null, "value")).toBeNull();
  expect(() => bindgen.invokeNullableStringCallback(() => undefined as any, null)).toThrow(TypeError);

  expect(bindgen.echoNullableBuffer(null)).toBeNull();
  expect([...bindgen.echoNullableBuffer(new Uint8Array([4, 5, 6]))!]).toEqual([4, 5, 6]);
});

it("typed domain errors", () => {
  expect(bindgen.domainError(0, "unused")).toBe(42);

  try {
    bindgen.domainError(1, "dynamic failure");
    throw new Error("expected domainError to throw");
  } catch (error: any) {
    expect(error).toBeInstanceOf(RangeError);
    expect(error.message).toBe("dynamic failure");
    expect(error.code).toBe("ERR_BINDGEN_TEST");
    expect(String(error)).toBe("RangeError [ERR_BINDGEN_TEST]: dynamic failure");
  }

  try {
    bindgen.domainError(2, "unused");
    throw new Error("expected domainError to throw");
  } catch (error: any) {
    expect(error).toBeInstanceOf(TypeError);
    expect(error.message).toBe("fixed bindgen failure");
    expect(error.code).toBeUndefined();
  }

  try {
    bindgen.domainError(3, "unused");
    throw new Error("expected domainError to throw");
  } catch (error: any) {
    expect(error).toBeInstanceOf(Error);
    expect(error.message).toBe("ENOENT: no such file or directory, open '/bindgen/missing' -> '/bindgen/dest'");
    expect(error.code).toBe("ENOENT");
    expect(error.errno).toBe(-2);
    expect(error.path).toBe("/bindgen/missing");
    expect(error.dest).toBe("/bindgen/dest");
    expect(error.syscall).toBe("open");
    expect(error.fd).toBeUndefined();
    expect(error.hostname).toBeUndefined();
  }
});

it("typed completions", async () => {
  await expect(bindgen.asyncResult(0, "unused")).resolves.toBe(123);

  try {
    await bindgen.asyncResult(1, "async failure");
    throw new Error("expected asyncResult to reject");
  } catch (error: any) {
    expect(error).toBeInstanceOf(RangeError);
    expect(error.message).toBe("async failure");
    expect(error.code).toBe("ERR_BINDGEN_TEST");
  }

  await expect(bindgen.asyncResult(2, "unused")).rejects.toThrow("binding completion dropped");
  await expect(bindgen.asyncResult(3, "unused")).resolves.toBe(321);
  await expect(bindgen.asyncResult(4, "unused")).resolves.toBe(456);
  await expect(bindgen.asyncResult(5, "delayed failure")).rejects.toThrow("delayed failure");
  await expect(bindgen.asyncEcho("completion transfer 😀")).resolves.toBe("completion transfer 😀");
  await expect(bindgen.asyncUTF8Strings()).resolves.toEqual(["plain", "Grüße", "f�"]);
  const label = { rooted: true };
  await expect(bindgen.asyncMaterialized(20, label)).resolves.toEqual({ value: 41, label });

  try {
    await bindgen.asyncResult(10, "unused");
    throw new Error("expected asyncResult to reject");
  } catch (error: any) {
    expect(error).toBeInstanceOf(Error);
    expect(error.message).toBe("ENOENT: no such file or directory, open '/bindgen/missing' -> '/bindgen/dest'");
    expect(error.code).toBe("ENOENT");
    expect(error.errno).toBe(-2);
    expect(error.path).toBe("/bindgen/missing");
    expect(error.dest).toBe("/bindgen/dest");
    expect(error.syscall).toBe("open");
  }
});

it("weak allocation failure rolls back wrapper construction", () => {
  Bun.gc(true);
  const destroyedBefore = bindgen.Counter.destroyedCount;
  bindgen.setWeakAllocationFailureCountdown(0);
  try {
    expect(() => new bindgen.Counter(7)).toThrow("Out of memory");
  } finally {
    bindgen.setWeakAllocationFailureCountdown(-1);
  }
  expect(bindgen.Counter.destroyedCount).toBe(destroyedBefore + 1);
  expect(new bindgen.Counter(8).value).toBe(8);
});

it("wrapper downgrade and upgrade reuse their weak handle", () => {
  const counter = new bindgen.Counter(7);
  try {
    expect(
      bindgen.inspectCounterWrapperHandles(counter, () => bindgen.setWeakAllocationFailureCountdown(0)),
    ).toBeTrue();
    expect(() => new bindgen.Counter(8)).toThrow("Out of memory");
  } finally {
    bindgen.setWeakAllocationFailureCountdown(-1);
  }
  expect(counter.value).toBe(7);
});

it("weak wrapper reads preserve pending exceptions", () => {
  const counter = new bindgen.Counter(7);
  const failure = { fromWeakRead: true };
  let caught: unknown;
  try {
    bindgen.inspectCounterWrapperHandles(counter, () => {
      Bun.gc(true);
      throw failure;
    });
  } catch (error) {
    caught = error;
  }
  expect(caught).toBe(failure);
  expect(bindgen.inspectCounterWrapperHandles(counter, () => Bun.gc(true))).toBeTrue();
});

it("weak wrapper reads propagate worker termination", async () => {
  const source = `
    import { bindgen } from "bun:internal-for-testing";
    bindgen.inspectCounterWrapperHandles(new bindgen.Counter(7), () => {
      postMessage("ready");
      while (true) {}
    });
  `;
  const url = URL.createObjectURL(new Blob([source], { type: "text/javascript" }));
  const worker = new Worker(url);
  const closed = new Promise<void>(resolve => worker.addEventListener("close", () => resolve(), { once: true }));
  try {
    expect(
      await new Promise((resolve, reject) => {
        worker.onmessage = event => resolve(event.data);
        worker.onerror = reject;
      }),
    ).toBe("ready");
  } finally {
    worker.terminate();
    await closed;
    URL.revokeObjectURL(url);
  }
});

it("weak completion discards a result after its promise is collected", async () => {
  const weak = (() => new WeakRef(bindgen.asyncWeakEcho(1, "collected promise")))();
  let collected = false;
  for (let attempt = 0; attempt < 20; attempt++) {
    await Bun.sleep(0);
    Bun.gc(true);
    if (weak.deref() === undefined) {
      collected = true;
      break;
    }
  }
  expect(collected).toBeTrue();
  await expect(bindgen.asyncResult(7, "open gate")).resolves.toBe(789);
});

it("pending completion activity keeps a standalone event loop alive", async () => {
  const child = Bun.spawn({
    cmd: [
      process.execPath,
      "-e",
      `import { bindgen } from "bun:internal-for-testing";
       bindgen.asyncPendingEcho("standalone pending activity").then(console.log);`,
    ],
    env: { ...process.env, BUN_DEBUG_QUIET_LOGS: "1" },
    stdout: "pipe",
    stderr: "pipe",
  });
  const [exitCode, stdout, stderr] = await Promise.all([
    child.exited,
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
  ]);
  if (exitCode !== 0) throw new Error(`standalone completion failed (${exitCode}): ${stderr}`);
  expect(stdout.trim()).toBe("standalone pending activity");
});

it("completion endpoints detach during worker VM shutdown", async () => {
  const source = `
    import { bindgen } from "bun:internal-for-testing";
    bindgen.asyncResult(6, "late transferred payload 😀");
    bindgen.asyncResult(9, "abandoned completion after detach");
    bindgen.asyncMaterialized(-1, { rootedUntilDetach: true });
    postMessage("ready");
    setInterval(() => {}, 1000);
  `;
  const url = URL.createObjectURL(new Blob([source], { type: "text/javascript" }));
  const worker = new Worker(url);
  await new Promise<void>((resolve, reject) => {
    worker.onmessage = () => resolve();
    worker.onerror = reject;
  });
  await terminateWorker(worker);
  URL.revokeObjectURL(url);
  await expect(bindgen.asyncResult(7, "open gate")).resolves.toBe(789);
});

it("generated unique classes", () => {
  const { Counter } = bindgen;
  const counter = new Counter(4);

  expect(Counter.kind()).toBe("Counter");
  expect(counter.newTarget).toBe(Counter);
  expect(counter.value).toBe(4);
  expect(counter.invalidatableValue).toBe(4);
  expect(counter.increment()).toBe(5);
  expect(counter.invalidatableValue).toBe(4);
  counter.invalidateValueCache();
  expect(counter.invalidatableValue).toBe(5);
  expect(counter.increment(3)).toBe(8);
  expect(counter.sum(2)).toBe(10);
  expect(counter.sum(4, 5)).toBe(9);
  const coercionOrder: string[] = [];
  const coercible = (name: string, value: number) => ({
    valueOf() {
      coercionOrder.push(name);
      return value;
    },
  });
  expect(counter.sum(coercible("left", 4) as any, coercible("right", 5) as any)).toBe(9);
  expect(coercionOrder).toEqual(["left", "right"]);
  expect(counter.incrementViaBuiltin(2)).toBe(20);
  expect(counter.incrementViaCpp(4)).toBe(12);
  expect(counter.doubledViaBuiltin).toBe(20);
  expect(counter.value).toBe(10);
  expect(bindgen.readCounterValue(counter)).toBe(10);
  expect(bindgen.inspectCounterWrapperHandles(counter)).toBeTrue();
  expect(() => bindgen.readCounterValue({})).toThrow("Expected a Counter instance");
  counter.value = 19;
  expect(counter.value).toBe(19);
  expect(+counter).toBe(19);
  expect(Object.getOwnPropertyDescriptor(Counter.prototype, Symbol.toPrimitive)?.enumerable).toBeFalse();
  expect((counter as any)[Symbol.toStringTag]).toBe("Counter");
  expect("privateIncrement" in counter).toBeFalse();
  expect(Bun.inspect(counter)).toBe("GeneratedCounter");
  let invalidThisError: unknown;
  try {
    Reflect.set(Counter.prototype, "value", 1, {});
  } catch (error) {
    invalidThisError = error;
  }
  expect(invalidThisError).toBeInstanceOf(TypeError);
  expect((invalidThisError as any).code).toBe("ERR_INVALID_THIS");
  expect(Counter.defaultValue).toBe(11);
  Counter.defaultValue = 27;
  expect(Counter.defaultValue).toBe(27);
  expect(counter.cached).toBeUndefined();
  expect("hiddenCached" in counter).toBeFalse();

  const cached = { retained: true };
  counter.cached = cached;
  expect(counter.cached).toBe(cached);

  counter.cachedString = "cached string";
  expect(counter.cachedString).toBe("cached string");
  counter.cachedString = null;
  expect(counter.cachedString).toBeNull();
  expect(() => {
    counter.cachedString = 42 as any;
  }).toThrow("cachedString must be a string");

  const weakCached = (() => {
    const value = { visited: true };
    counter.cached = value;
    return new WeakRef(value);
  })();
  Bun.gc(true);
  expect(weakCached.deref()).toBe(counter.cached);

  class DerivedCounter extends Counter {}
  const derived = new DerivedCounter(2);
  expect(derived).toBeInstanceOf(DerivedCounter);
  expect(derived).toBeInstanceOf(Counter);
  expect(derived.newTarget).toBe(DerivedCounter);
  expect(derived.increment()).toBe(3);

  expect(new Counter().value).toBe(0);
  expect(() => Counter()).toThrow("cannot be invoked without 'new'");
  invalidThisError = undefined;
  try {
    Counter.prototype.increment.call({});
  } catch (error) {
    invalidThisError = error;
  }
  expect(invalidThisError).toBeInstanceOf(TypeError);
  expect((invalidThisError as any).code).toBe("ERR_INVALID_THIS");
  expect(() => new Counter(null)).toThrow("initial must be a number");
});

it("destroys native state when eager constructor caching throws", () => {
  const { Counter } = bindgen;
  const destroyedBefore = Counter.destroyedCount;

  expect(() => new Counter(-2147483648)).toThrow("Counter eager cache failed");
  expect(Counter.destroyedCount).toBeGreaterThan(destroyedBefore);
});

it.each(["Counter", "SharedCounter"] as const)("native adoption consumes failed %s construction", name => {
  const Class = bindgen[name];
  const destroyedBefore = Class.destroyedCount;
  const failure = new Error("adoption callback failed");
  let caught;
  try {
    Class.adoptAfterCallback(() => {
      throw failure;
    });
  } catch (error) {
    caught = error;
  }
  expect(caught).toBe(failure);
  expect(Class.destroyedCount).toBe(destroyedBefore + 1);
});

it("failed native rewrapping preserves an existing shared wrapper", () => {
  const { SharedCounter } = bindgen;
  const counter = new SharedCounter(17);
  const destroyedBefore = SharedCounter.destroyedCount;
  const failure = new Error("rewrapping callback failed");
  let caught;
  try {
    SharedCounter.wrapAfterCallback(counter, () => {
      throw failure;
    });
  } catch (error) {
    caught = error;
  }
  expect(caught).toBe(failure);
  expect(counter.increment()).toBe(18);
  expect(SharedCounter.destroyedCount).toBe(destroyedBefore);
  expect(SharedCounter.wrapAfterCallback(counter, () => {})).toBe(counter);
});

it("generated native class inheritance", () => {
  const { Counter, ScaledCounter } = bindgen;
  const counter = new ScaledCounter(3, 4);

  expect(counter).toBeInstanceOf(ScaledCounter);
  expect(counter).toBeInstanceOf(Counter);
  expect(Object.getPrototypeOf(ScaledCounter)).toBe(Counter);
  expect(Object.getPrototypeOf(ScaledCounter.prototype)).toBe(Counter.prototype);
  expect(counter.newTarget).toBe(ScaledCounter);
  expect(counter.value).toBe(3);
  expect(counter.increment(2)).toBe(5);
  expect(counter.scale()).toBe(20);
  expect(counter.factor).toBe(4);
  expect(bindgen.readCounterValue(counter)).toBe(20);
  expect(+counter).toBe(20);
  expect(Bun.inspect(counter)).toBe("GeneratedCounter");
  expect(ScaledCounter.kind()).toBe("Counter");

  const parentCached = { parent: true };
  const childCached = { child: true };
  counter.cached = parentCached;
  counter.scaledCached = childCached;
  expect(counter.cached).toBe(parentCached);
  expect(counter.scaledCached).toBe(childCached);
});

it("generated shared native class inheritance preserves ownership and identity", async () => {
  const { SharedCounter, SharedScaledCounter } = bindgen;
  const counter = new SharedScaledCounter(3, 4);

  expect(counter).toBeInstanceOf(SharedScaledCounter);
  expect(counter).toBeInstanceOf(SharedCounter);
  expect(Object.getPrototypeOf(SharedScaledCounter)).toBe(SharedCounter);
  expect(Object.getPrototypeOf(SharedScaledCounter.prototype)).toBe(SharedCounter.prototype);
  expect(counter.value).toBe(3);
  expect(counter.increment(2)).toBe(5);
  expect(counter.scale()).toBe(20);
  expect(counter.factor).toBe(4);
  expect(bindgen.readSharedCounterValue(counter)).toBe(20);
  expect(SharedCounter.identity(counter)).toBe(counter);

  let heldCounter: InstanceType<typeof SharedScaledCounter> | null = new SharedScaledCounter(7, 3);
  const heldWeak = new WeakRef(heldCounter);
  SharedCounter.holdForRealmTest(heldCounter);
  try {
    heldCounter = null;
    for (let attempt = 0; attempt < 20; attempt++) {
      await Bun.sleep(0);
      Bun.gc(true);
      if (heldWeak.deref() === undefined) break;
    }
    expect(heldWeak.deref()).toBeUndefined();
    const rebound = SharedCounter.heldForRealmTest() as InstanceType<typeof SharedScaledCounter>;
    expect(rebound).toBeInstanceOf(SharedScaledCounter);
    expect(rebound).toBeInstanceOf(SharedCounter);
    expect(rebound.value).toBe(7);
    expect(rebound.factor).toBe(3);
    expect(SharedCounter.heldForRealmTest()).toBe(rebound);
  } finally {
    SharedCounter.releaseForRealmTest();
  }

  const destroyedBefore = SharedScaledCounter.destroyedCount;
  const weak = (() => new WeakRef(new SharedScaledCounter(9, 2)))();
  for (let attempt = 0; attempt < 20; attempt++) {
    await Bun.sleep(0);
    Bun.gc(true);
    if (weak.deref() === undefined && SharedScaledCounter.destroyedCount > destroyedBefore) break;
  }
  expect(weak.deref()).toBeUndefined();
  expect(SharedScaledCounter.destroyedCount).toBeGreaterThan(destroyedBefore);
});

it("generated class pending activity retains its wrapper", async () => {
  const { Counter } = bindgen;
  let counter: InstanceType<typeof Counter> | null = new Counter(-24_680);
  expect(counter.value).toBe(-24_680);
  const weak = new WeakRef(counter);
  counter = null;

  for (let attempt = 0; attempt < 10; attempt++) {
    Bun.gc(true);
    await Bun.sleep(0);
  }
  expect(weak.deref()).toBeDefined();
  expect(
    (() => {
      const live = weak.deref();
      if (!live) return false;
      live.value = 0;
      return true;
    })(),
  ).toBeTrue();
  for (let attempt = 0; attempt < 50 && weak.deref() !== undefined; attempt++) {
    Bun.gc(true);
    await Bun.sleep(0);
  }
  expect(weak.deref()).toBeUndefined();
});

it("generated classes participate in structured clone", () => {
  const { CloneBox } = bindgen;
  const source = new CloneBox(-123_456);
  const clone = structuredClone(source);

  expect(clone).toBeInstanceOf(CloneBox);
  expect(clone).not.toBe(source);
  expect(clone.value).toBe(-123_456);
  source.value = 17;
  expect(clone.value).toBe(-123_456);
  clone.value = 29;
  expect(source.value).toBe(17);

  const graph = structuredClone({ first: source, second: source });
  expect(graph.first).toBeInstanceOf(CloneBox);
  expect(graph.first).toBe(graph.second);
  expect(graph.first).not.toBe(source);
  expect(graph.first.value).toBe(17);
});

it("structured clone failures preserve transfer buffers and release native borrows", () => {
  const source = new bindgen.CloneBox(42);
  const buffer = new ArrayBuffer(8);
  new Uint8Array(buffer).set([1, 2, 3]);
  source.setSerializationFailure(true);

  expect(() => structuredClone({ buffer, source }, { transfer: [buffer] })).toThrow("Out of memory");
  expect(buffer.byteLength).toBe(8);
  expect([...new Uint8Array(buffer)]).toEqual([1, 2, 3, 0, 0, 0, 0, 0]);
  expect(source.value).toBe(42);

  source.setSerializationFailure(false);
  const clone = structuredClone({ buffer, source }, { transfer: [buffer] });
  expect(buffer.byteLength).toBe(0);
  expect(clone.buffer.byteLength).toBe(8);
  expect(clone.source.value).toBe(42);
});

it("structured clone validates every buffer before committing transfers", () => {
  const first = Uint8Array.from([1, 2, 3]).buffer;
  const later = Uint8Array.from([4, 5, 6]).buffer;
  const input = {
    first,
    get detachLater() {
      later.transfer();
      return 0;
    },
  };
  expect(() => structuredClone(input, { transfer: [first, later] })).toThrow(DOMException);
  expect([...new Uint8Array(first)]).toEqual([1, 2, 3]);
  expect(later.detached).toBe(true);

  const leased = new Uint8Array(64 * 1024);
  bindgen.inspectLeaseAfterCallback(leased, () => {
    expect(() => structuredClone({ first }, { transfer: [first, leased.buffer] })).toThrow(DOMException);
    expect([...new Uint8Array(first)]).toEqual([1, 2, 3]);
    expect(leased.buffer.detached).toBe(false);
  });

  const resizable = new ArrayBuffer(8, { maxByteLength: 16 });
  new Uint8Array(resizable).set([7, 8, 9]);
  const clone = structuredClone({ first, resizable }, { transfer: [first, resizable] });
  expect(first.detached).toBe(true);
  expect(resizable.detached).toBe(true);
  expect([...new Uint8Array(clone.first)]).toEqual([1, 2, 3]);
  expect(clone.resizable.resizable).toBe(true);
  expect(clone.resizable.maxByteLength).toBe(16);
  expect([...new Uint8Array(clone.resizable)]).toEqual([7, 8, 9, 0, 0, 0, 0, 0]);
});

it("structured clone enforces native storage and transfer declarations", () => {
  const source = new bindgen.CloneBox(42);
  for (const [forTransfer, forStorage] of [
    [true, false],
    [false, true],
    [true, true],
  ]) {
    const buffer = Uint8Array.from([1, 2, 3]).buffer;
    let laterGetterCalls = 0;
    const input = {
      buffer,
      source,
      get later() {
        laterGetterCalls++;
        return 1;
      },
    };
    let failure: unknown;
    try {
      structuredCloneAdvanced(input, [buffer], forTransfer, forStorage, "default");
    } catch (error) {
      failure = error;
    }
    expect(failure).toBeInstanceOf(DOMException);
    expect(failure).toHaveProperty("name", "DataCloneError");
    expect([...new Uint8Array(buffer)]).toEqual([1, 2, 3]);
    expect(laterGetterCalls).toBe(0);
    expect(source.value).toBe(42);
  }
});

it("generated shared classes retain and release native references", async () => {
  const { SharedCounter } = bindgen;
  const counter = new SharedCounter(5);
  const keepAlive = [counter];
  expect(counter.value).toBe(5);
  expect(counter.increment(2)).toBe(7);
  expect(await counter.incrementAsync(3)).toBe(10);
  expect(counter.value).toBe(10);
  expect(bindgen.readSharedCounterValue(counter)).toBe(10);
  expect(SharedCounter.identity(counter)).toBe(counter);
  expect(() => bindgen.readSharedCounterValue({})).toThrow("Expected a SharedCounter instance");
  expect(() => SharedCounter.identity({})).toThrow("Expected a SharedCounter instance");

  class DerivedSharedCounter extends SharedCounter {}
  const derived = new DerivedSharedCounter(3);
  expect(SharedCounter.identity(derived)).toBe(derived);

  const destroyedBefore = SharedCounter.destroyedCount;
  const weak = (() => new WeakRef(new SharedCounter(9)))();
  for (let attempt = 0; attempt < 20; attempt++) {
    await Bun.sleep(0);
    Bun.gc(true);
    if (weak.deref() === undefined && SharedCounter.destroyedCount > destroyedBefore) break;
  }
  expect(weak.deref()).toBeUndefined();
  expect(SharedCounter.destroyedCount).toBeGreaterThan(destroyedBefore);
  expect(keepAlive[0]).toBe(counter);
});

it("generated shared classes keep per-realm identity", async () => {
  const { SharedCounter } = bindgen;
  const realm = new ShadowRealm();
  const fixture = new URL("./fixtures/bindgen-shadow-realm.ts", import.meta.url).href;
  const hold = await realm.importValue(fixture, "holdSharedCounter");
  const increment = await realm.importValue(fixture, "incrementHeldSharedCounter");

  try {
    expect(hold(31)).toBe(31);
    const weakOuter = (() => new WeakRef(SharedCounter.heldForRealmTest() as object))();
    for (let attempt = 0; attempt < 20; attempt++) {
      await Bun.sleep(0);
      Bun.gc(true);
      if (weakOuter.deref() === undefined) break;
    }
    expect(weakOuter.deref()).toBeUndefined();

    const outer = SharedCounter.heldForRealmTest() as InstanceType<typeof SharedCounter>;
    expect(SharedCounter.heldForRealmTest()).toBe(outer);
    expect(SharedCounter.identity(outer)).toBe(outer);
    expect(outer.value).toBe(31);
    expect(increment(4)).toBe(35);
    expect(outer.value).toBe(35);
  } finally {
    SharedCounter.releaseForRealmTest();
  }
});

it("deferred shared class handles can release their last reference off-thread", async () => {
  const { SharedCounter } = bindgen;
  const destroyedBefore = SharedCounter.destroyedCount;
  let counter: InstanceType<typeof SharedCounter> | null = new SharedCounter(47);
  const weak = new WeakRef(counter);
  SharedCounter.holdForRealmTest(counter);
  counter = null;
  let released = false;

  try {
    for (let attempt = 0; attempt < 20; attempt++) {
      await Bun.sleep(0);
      Bun.gc(true);
      if (weak.deref() === undefined) break;
    }
    expect(weak.deref()).toBeUndefined();

    SharedCounter.releaseHeldOffThreadForTest();
    released = true;
    for (let attempt = 0; attempt < 20; attempt++) {
      await Bun.sleep(0);
      if (SharedCounter.destroyedCount > destroyedBefore) break;
    }
    expect(SharedCounter.destroyedCount).toBeGreaterThan(destroyedBefore);
  } finally {
    if (!released) SharedCounter.releaseForRealmTest();
  }
});

it("deferred shared class finalization drains during worker VM shutdown", async () => {
  const destroyedBefore = bindgen.SharedCounter.destroyedCount;
  const source = `
    import { bindgen } from "bun:internal-for-testing";
    globalThis.counter = new bindgen.SharedCounter(73);
    postMessage({ value: globalThis.counter.value, destroyedCount: bindgen.SharedCounter.destroyedCount });
    setInterval(() => {}, 1000);
  `;
  const url = URL.createObjectURL(new Blob([source], { type: "text/javascript" }));
  const worker = new Worker(url);
  const workerState = await new Promise<{ value: number; destroyedCount: number }>((resolve, reject) => {
    worker.onmessage = event => resolve(event.data);
    worker.onerror = reject;
  });
  expect(workerState).toEqual({ value: 73, destroyedCount: destroyedBefore });
  await terminateWorker(worker);
  URL.revokeObjectURL(url);

  for (let attempt = 0; attempt < 20; attempt++) {
    if (bindgen.SharedCounter.destroyedCount > destroyedBefore) break;
    await Bun.sleep(0);
  }
  expect(bindgen.SharedCounter.destroyedCount).toBeGreaterThan(destroyedBefore);
});
