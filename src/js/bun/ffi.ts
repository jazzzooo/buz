const FFIType = {
  "0": 0,
  "1": 1,
  "2": 2,
  "3": 3,
  "4": 4,
  "5": 5,
  "6": 6,
  "7": 7,
  "8": 8,
  "9": 9,
  "10": 10,
  "11": 11,
  "12": 12,
  "13": 13,
  "14": 14,
  "15": 15,
  "16": 16,
  "17": 17,
  "18": 18,
  "19": 19,
  "20": 20,
  bool: 11,
  c_int: 5,
  c_uint: 6,
  char: 0,
  "char*": 12,
  double: 9,
  f32: 10,
  f64: 9,
  float: 10,
  i16: 3,
  i32: 5,
  i64: 7,
  i8: 1,
  int: 5,
  int16_t: 3,
  int32_t: 5,
  int64_t: 7,
  int8_t: 1,
  isize: 7,
  u16: 4,
  u32: 6,
  u64: 8,
  u8: 2,
  uint16_t: 4,
  uint32_t: 6,
  uint64_t: 8,
  uint8_t: 2,
  usize: 8,
  size_t: 8,
  "void*": 12,
  ptr: 12,
  pointer: 12,
  void: 13,
  cstring: 14,
  i64_fast: 15,
  u64_fast: 16,
  function: 17,
  callback: 17,
  fn: 17,
  napi_env: 18,
  napi_value: 19,
  buffer: 20,
};

const suffix = process.platform === "win32" ? "dll" : process.platform === "darwin" ? "dylib" : "so";
const ptr = $bindgenFn("FFI.schema.zig", "ptr");
const toBuffer = $bindgenFn("FFI.schema.zig", "toBuffer");
const toArrayBuffer = $bindgenFn("FFI.schema.zig", "toArrayBuffer");
const nativeViewSourceSymbols = $bindgenFn("FFI.schema.zig", "viewSourceSymbols");
const nativeViewSourceCallback = $bindgenFn("FFI.schema.zig", "viewSourceCallback");
const viewSource = (definition, isCallback) =>
  isCallback ? nativeViewSourceCallback(definition) : nativeViewSourceSymbols(definition);
const BunCString = $bindgenFn("FFI.schema.zig", "CString");
const nativeLinkSymbols = $bindgenFn("FFI.schema.zig", "linkSymbols");
const nativeDLOpen = $bindgenFn("FFI.schema.zig", "dlopen");
const nativeCallback = $bindgenFn("FFI.schema.zig", "callback");
const functionSignature = $bindgenFn("FFI.schema.zig", "functionSignature");
const invoke = $bindgenFn("FFI.schema.zig", "invoke");
const ccFn = $bindgenFn("FFI.schema.zig", "compile");

function makeCallback(callback, returnType) {
  return (...values) => {
    const value = callback(...values);
    return { type: returnType, value: returnType === "void_type" ? undefined : value };
  };
}

class JSCallback {
  constructor(cb, options) {
    const { resource, ptr, threadsafe } = nativeCallback(options, cb, makeCallback);
    this.#resource = resource;
    this.ptr = ptr;
    this.#threadsafe = threadsafe;
    // Failed native result conversion must be able to release an unpublished endpoint.
    this.#resource.publish();
  }

  ptr;
  #resource;
  #threadsafe;

  get threadsafe() {
    return this.#threadsafe;
  }

  [Symbol.toPrimitive]() {
    const { ptr } = this;
    return typeof ptr === "number" || typeof ptr === "bigint" ? ptr : 0;
  }

  close() {
    this.#resource?.close();
    this.ptr = null;
    this.#resource = null;
  }

  [Symbol.dispose]() {
    this.close();
  }
}

const copiedCString = Symbol("copiedCString");

class CString extends String {
  constructor(ptr, byteOffset?, byteLength?) {
    const copied = byteOffset === copiedCString;
    super(copied ? byteLength : ptr == null || ptr === 0 || ptr === 0n ? "" : BunCString(ptr, byteOffset, byteLength));
    this.ptr = typeof ptr === "number" || typeof ptr === "bigint" ? ptr : 0;
    if (!copied) {
      this.byteOffset = byteOffset;
      this.byteLength = byteLength;
    }
  }

  ptr;
  byteOffset;
  byteLength;
  #cachedArrayBuffer;

  get arrayBuffer() {
    if (this.#cachedArrayBuffer) return this.#cachedArrayBuffer;
    if (!this.ptr) return (this.#cachedArrayBuffer = new ArrayBuffer(0));
    return (this.#cachedArrayBuffer = toArrayBuffer(this.ptr, this.byteOffset, this.byteLength));
  }
}

function makeCallable(state) {
  const { name, argumentTypes, returnType, ptr } = functionSignature(state);
  const callable = (...values) => {
    const arguments_ = new Array(argumentTypes.length);
    for (let i = 0; i < argumentTypes.length; i++) {
      arguments_[i] = { type: argumentTypes[i], value: values[i] };
    }
    const result = invoke(state, arguments_);
    return returnType === "c_string" ? new CString(result.ptr, copiedCString, result.value) : result;
  };
  Object.defineProperties(callable, {
    name: { value: name, configurable: true },
    length: { value: argumentTypes.length, configurable: true },
    ptr: { value: ptr, enumerable: true },
    native: { value: callable, enumerable: true },
  });
  return callable;
}

function wrapLibrary(library) {
  const symbols = library.symbols;
  for (const key of Object.keys(symbols)) symbols[key] = makeCallable(symbols[key]);
  library.close = library.close.bind(library);
  return library;
}

function dlopen(path, options) {
  return wrapLibrary(nativeDLOpen(path, options));
}

function cc(options) {
  return wrapLibrary(ccFn(options));
}

function linkSymbols(options) {
  return wrapLibrary(nativeLinkSymbols(options));
}

let cFunctionI = 0;
function CFunction(options) {
  const identifier = `CFunction${cFunctionI++}`;
  const library = linkSymbols({ [identifier]: options });
  const callable = library.symbols[identifier];
  callable.close = library.close;
  return callable;
}

const native = {
  dlopen,
  callback: () => {
    throw new Error("Deprecated. Use new JSCallback(options, fn) instead");
  },
};

const read = {
  u8: $bindgenFn("FFI.schema.zig", "readerU8"),
  u16: $bindgenFn("FFI.schema.zig", "readerU16"),
  u32: $bindgenFn("FFI.schema.zig", "readerU32"),
  u64: $bindgenFn("FFI.schema.zig", "readerU64"),
  i8: $bindgenFn("FFI.schema.zig", "readerI8"),
  i16: $bindgenFn("FFI.schema.zig", "readerI16"),
  i32: $bindgenFn("FFI.schema.zig", "readerI32"),
  i64: $bindgenFn("FFI.schema.zig", "readerI64"),
  f32: $bindgenFn("FFI.schema.zig", "readerF32"),
  f64: $bindgenFn("FFI.schema.zig", "readerF64"),
  ptr: $bindgenFn("FFI.schema.zig", "readerPtr"),
  intptr: $bindgenFn("FFI.schema.zig", "readerIntptr"),
};

export default {
  CFunction,
  CString,
  FFIType,
  JSCallback,
  dlopen,
  linkSymbols,
  native,
  ptr,
  read,
  suffix,
  toArrayBuffer,
  toBuffer,
  viewSource,
  cc,
};
