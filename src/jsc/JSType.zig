/// Cell tags returned by the engine's `jsValueType` shim. Numeric values match
/// JSC::JSType; embedder tags occupy the high end of the range.
pub const JSType = enum(u8) {
    Cell = 0,
    Structure = 1,
    String = 2,
    HeapBigInt = 3,
    Symbol = 4,
    GetterSetter = 5,
    CustomGetterSetter = 6,
    APIValueWrapper = 7,
    NativeExecutable = 8,
    ProgramExecutable = 9,
    ModuleProgramExecutable = 10,
    EvalExecutable = 11,
    FunctionExecutable = 12,
    UnlinkedFunctionExecutable = 13,
    UnlinkedProgramCodeBlock = 14,
    UnlinkedModuleProgramCodeBlock = 15,
    UnlinkedEvalCodeBlock = 16,
    UnlinkedFunctionCodeBlock = 17,
    CodeBlock = 18,
    JSCellButterfly = 19,
    JSSourceCode = 20,
    SlimPromiseReaction = 21,
    FullPromiseReaction = 22,
    PromiseAllContext = 23,
    PromiseAllGlobalContext = 24,
    WebAssemblyStreamingContext = 25,
    JSMicrotaskDispatcher = 26,
    ModuleRegistryEntry = 27,
    ModuleLoadingContext = 28,
    ModuleLoaderPayload = 29,
    ModuleGraphLoadingState = 30,
    JSModuleLoader = 31,
    Sentinel = 32,
    Object = 33,
    FinalObject = 34,
    JSCallee = 35,
    JSFunction = 36,
    InternalFunction = 37,
    NullSetterFunction = 38,
    BooleanObject = 39,
    NumberObject = 40,
    ErrorInstance = 41,
    GlobalProxy = 42,
    DirectArguments = 43,
    ScopedArguments = 44,
    ClonedArguments = 45,
    Array = 46,
    DerivedArray = 47,
    ArrayBuffer = 48,
    Int8Array = 49,
    Uint8Array = 50,
    Uint8ClampedArray = 51,
    Int16Array = 52,
    Uint16Array = 53,
    Int32Array = 54,
    Uint32Array = 55,
    Float16Array = 56,
    Float32Array = 57,
    Float64Array = 58,
    BigInt64Array = 59,
    BigUint64Array = 60,
    DataView = 61,
    GlobalObject = 62,
    GlobalLexicalEnvironment = 63,
    LexicalEnvironment = 64,
    ModuleEnvironment = 65,
    StrictEvalActivation = 66,
    WithScope = 67,
    AsyncDisposableStack = 68,
    DisposableStack = 69,
    ModuleNamespaceObject = 70,
    ShadowRealm = 71,
    RegExpObject = 72,
    JSDate = 73,
    ProxyObject = 74,
    Generator = 75,
    AsyncFunctionGenerator = 76,
    AsyncGenerator = 77,
    JSArrayIterator = 78,
    Iterator = 79,
    IteratorHelper = 80,
    MapIterator = 81,
    SetIterator = 82,
    StringIterator = 83,
    WrapForValidIterator = 84,
    RegExpStringIterator = 85,
    AsyncFromSyncIterator = 86,
    JSPromise = 87,
    Map = 88,
    Set = 89,
    WeakMap = 90,
    WeakSet = 91,
    WebAssemblyModule = 92,
    WebAssemblyInstance = 93,
    WebAssemblyGCObject = 94,
    StringObject = 95,
    DerivedStringObject = 96,
    InternalFieldTuple = 97,

    MaxJS = 0b11111111,
    Event = 0b11101111,
    DOMWrapper = 0b11101110,
    EmbedderArrayLike = 0b11101101,

    /// An embedder type handled through its `toJSON()` method.
    JSAsJSONType = 0b11110000 | 1,
    _,

    pub const min_typed_array: JSType = .Int8Array;
    pub const max_typed_array: JSType = .DataView;

    pub fn canGet(this: JSType) bool {
        return switch (this) {
            .Array,
            .ArrayBuffer,
            .BigInt64Array,
            .BigUint64Array,
            .BooleanObject,
            .DOMWrapper,
            .DataView,
            .DerivedArray,
            .DerivedStringObject,
            .ErrorInstance,
            .Event,
            .FinalObject,
            .Float32Array,
            .Float16Array,
            .Float64Array,
            .GlobalObject,
            .Int16Array,
            .Int32Array,
            .Int8Array,
            .InternalFunction,
            .JSArrayIterator,
            .AsyncFunctionGenerator,
            .AsyncGenerator,
            .JSDate,
            .JSFunction,
            .Generator,
            .Map,
            .MapIterator,
            .JSPromise,
            .Set,
            .SetIterator,
            .IteratorHelper,
            .Iterator,
            .StringIterator,
            .WeakMap,
            .WeakSet,
            .ModuleNamespaceObject,
            .NumberObject,
            .Object,
            .ProxyObject,
            .RegExpObject,
            .ShadowRealm,
            .StringObject,
            .Uint16Array,
            .Uint32Array,
            .Uint8Array,
            .Uint8ClampedArray,
            .WebAssemblyModule,
            .WebAssemblyInstance,
            .WebAssemblyGCObject,
            => true,
            else => false,
        };
    }

    pub inline fn isObject(this: JSType) bool {
        // inline constexpr bool isObjectType(JSType type) { return type >= ObjectType; }
        return @backingInt(this) >= @backingInt(JSType.Object);
    }

    pub fn isFunction(this: JSType) bool {
        return switch (this) {
            .JSFunction, .FunctionExecutable, .InternalFunction => true,
            else => false,
        };
    }

    pub fn typedArrayElementSize(this: JSType) ?u8 {
        return switch (this) {
            .Uint8Array, .Uint8ClampedArray, .Int8Array => 1,
            .Uint16Array, .Int16Array, .Float16Array => 2,
            .Uint32Array, .Int32Array, .Float32Array => 4,
            .BigUint64Array, .BigInt64Array, .Float64Array => 8,
            else => null,
        };
    }

    pub fn isHidden(this: JSType) bool {
        return switch (this) {
            .APIValueWrapper,
            .NativeExecutable,
            .ProgramExecutable,
            .ModuleProgramExecutable,
            .EvalExecutable,
            .FunctionExecutable,
            .UnlinkedFunctionExecutable,
            .UnlinkedProgramCodeBlock,
            .UnlinkedModuleProgramCodeBlock,
            .UnlinkedEvalCodeBlock,
            .UnlinkedFunctionCodeBlock,
            .CodeBlock,
            .JSCellButterfly,
            .JSSourceCode,
            .SlimPromiseReaction,
            .FullPromiseReaction,
            .PromiseAllContext,
            .PromiseAllGlobalContext,
            => true,
            else => false,
        };
    }

    pub inline fn isString(this: JSType) bool {
        return this == .String;
    }

    pub inline fn isStringObject(this: JSType) bool {
        return this == .StringObject;
    }

    pub inline fn isStringObjectLike(this: JSType) bool {
        return this == .StringObject or this == .DerivedStringObject;
    }

    pub inline fn isStringLike(this: JSType) bool {
        return switch (this) {
            .String, .StringObject, .DerivedStringObject => true,
            else => false,
        };
    }

    pub inline fn isArray(this: JSType) bool {
        return switch (this) {
            .Array, .DerivedArray => true,
            else => false,
        };
    }

    pub inline fn isArrayLike(this: JSType) bool {
        return switch (this) {
            .Array,
            .DerivedArray,

            .ArrayBuffer,
            .BigInt64Array,
            .BigUint64Array,
            .Float32Array,
            .Float16Array,
            .Float64Array,
            .Int16Array,
            .Int32Array,
            .Int8Array,
            .Uint16Array,
            .Uint32Array,
            .Uint8Array,
            .Uint8ClampedArray,
            => true,
            else => false,
        };
    }

    pub inline fn isSet(this: JSType) bool {
        return switch (this) {
            .Set, .WeakSet => true,
            else => false,
        };
    }

    pub inline fn isMap(this: JSType) bool {
        return switch (this) {
            .Map, .WeakMap => true,
            else => false,
        };
    }

    pub inline fn isIndexable(this: JSType) bool {
        return switch (this) {
            .Object,
            .FinalObject,
            .Array,
            .DerivedArray,
            .ErrorInstance,
            .JSFunction,
            .InternalFunction,

            .ArrayBuffer,
            .BigInt64Array,
            .BigUint64Array,
            .Float32Array,
            .Float16Array,
            .Float64Array,
            .Int16Array,
            .Int32Array,
            .Int8Array,
            .Uint16Array,
            .Uint32Array,
            .Uint8Array,
            .Uint8ClampedArray,
            => true,
            else => false,
        };
    }

    pub inline fn isArguments(this: JSType) bool {
        return switch (this) {
            .DirectArguments, .ClonedArguments, .ScopedArguments => true,
            else => false,
        };
    }
};
