const { normalizeShellTemplateValue } = require("internal/shell") as typeof import("internal/shell");

// Hardcoded module "bun:internal-for-testing"

// If you want to test an internal API, add a binding into this file.
//
// Then at test time: import ... from "bun:internal-for-testing"
//
// In a debug build, the import is always allowed.
// It is disallowed in release builds unless run in Bun's CI.

const fmtBinding = $bindgenFn("fmt_jsc.schema.zig", "fmtString");

export const nodeErrors = {
  createAbortError: $bindgenFn("ErrorCode.schema.zig", "makeAbortError"),
  createWithCode: $bindgenFn("ErrorCode.schema.zig", "makeErrorWithCode"),
  throwOutOfMemoryWithPendingException: $bindgenFn("bindgen_test.schema.zig", "throwOutOfMemoryWithPendingException"),
  settlePromiseWithPendingException: $bindgenFn("bindgen_test.schema.zig", "settlePromiseWithPendingException"),
};

export const highlightJavaScript = (code: string) => fmtBinding(code, "highlight-javascript");
export const highlightJavaScriptRedacted = (code: string) => fmtBinding(code, "highlight-javascript-redacted");
export const escapePowershell = (code: string) => fmtBinding(code, "escape-powershell");

export const canonicalizeIP = $bindgenFn("CanonicalizeIP.schema.zig", "canonicalizeIP");

// Runtime-dispatched SIMD xxHash3 kernel (src/highway_sys/Hash.cpp), driven
// directly so tests can exercise the Highway path independent of Bun.hash.
export const xxHash3ForTesting: (view: ArrayBufferView, seed?: number | bigint) => bigint = $bindgenFn(
  "bindgen_test.schema.zig",
  "xxHash3ForTesting",
);

export const SQL = [
  {
    open: $bindgenFn("SQLiteStatementHost.schema.zig", "jsSQLStatementOpenStatementFunction"),
    close: $bindgenFn("SQLiteStatementHost.schema.zig", "jsSQLStatementCloseStatementFunction"),
    prepare: $bindgenFn("SQLiteStatementHost.schema.zig", "jsSQLStatementPrepareStatementFunction"),
    run: $bindgenFn("SQLiteStatementHost.schema.zig", "jsSQLStatementExecuteFunction"),
    isInTransaction: $bindgenFn("SQLiteStatementHost.schema.zig", "jsSQLStatementIsInTransactionFunction"),
    loadExtension: $bindgenFn("SQLiteStatementHost.schema.zig", "jsSQLStatementLoadExtensionFunction"),
    setCustomSQLite: $bindgenFn("SQLiteStatementHost.schema.zig", "jsSQLStatementSetCustomSQLite"),
    serialize: $bindgenFn("SQLiteStatementHost.schema.zig", "jsSQLStatementSerialize"),
    deserialize: $bindgenFn("SQLiteStatementHost.schema.zig", "jsSQLStatementDeserialize"),
    controlInt32: $bindgenFn("SQLiteControl.schema.zig", "int32"),
    controlInt64: $bindgenFn("SQLiteControl.schema.zig", "int64"),
    controlRetry: $bindgenFn("SQLiteControl.schema.zig", "retry"),
    controlString: $bindgenFn("SQLiteControl.schema.zig", "string"),
    controlPragma: $bindgenFn("SQLiteControl.schema.zig", "pragma"),
    controlQuery: $bindgenFn("SQLiteControl.schema.zig", "query"),
    controlNotify: $bindgenFn("SQLiteControl.schema.zig", "notify"),
  },
  $bindgenFn("SQLiteStatementHost.schema.zig", "createInternalFieldTuple")(),
];

export const patchInternals = {
  parse: $bindgenFn("InternalTesting.schema.zig", "parsePatch"),
  apply: $bindgenFn("InternalTesting.schema.zig", "applyPatch"),
  makeDiff: $bindgenFn("InternalTesting.schema.zig", "makePatchDiff"),
};

export const internalSourceMap = {
  fromVLQ: $bindgenFn("InternalTesting.schema.zig", "sourceMapFromVLQ") as (vlq: string) => Uint8Array,
  toVLQ: $bindgenFn("InternalTesting.schema.zig", "sourceMapToVLQ") as (blob: Uint8Array) => string,
  find: $bindgenFn("InternalTesting.schema.zig", "sourceMapFind") as (
    blob: Uint8Array,
    line: number,
    col: number,
  ) => {
    generatedLine: number;
    generatedColumn: number;
    originalLine: number;
    originalColumn: number;
    sourceIndex: number;
  } | null,
};

const shellLex = $bindgenFn("InternalTesting.schema.zig", "shellLex");
const shellParse = $bindgenFn("InternalTesting.schema.zig", "shellParse");

export const sslCtxLiveCount = $bindgenFn("InternalTesting.schema.zig", "secureContextLiveCount");

export const escapeRegExp = $bindgenFn("InternalTesting.schema.zig", "escapeRegExp");
export const escapeRegExpForPackageNameMatching = $bindgenFn(
  "InternalTesting.schema.zig",
  "escapeRegExpForPackageNameMatching",
);

export const shellInternals = {
  lex: (a, ...b) => shellLex(a.raw, b.map(normalizeShellTemplateValue)),
  parse: (a, ...b) => shellParse(a.raw, b.map(normalizeShellTemplateValue)),
  /**
   * Checks if the given builtin is disabled on the current platform
   *
   * @example
   * ```typescript
   * const isDisabled = builtinDisabled("cp")
   * ```
   */
  builtinDisabled: $bindgenFn("InternalTesting.schema.zig", "shellDisabledOnThisPlatform"),
};

export const subprocessInternals = {
  injectStdioReadError: $bindgenFn("InternalTesting.schema.zig", "injectStdioReadError") as (
    subprocess: import("bun").Subprocess,
    kind: "stdout" | "stderr",
  ) => boolean,
};

const parseIniJSON = $bindgenFn("InternalTesting.schema.zig", "parseIni");
export const iniInternals = {
  parse: (contents: string) => JSON.parse(parseIniJSON(contents)),
  // loadNpmrc: (
  //   src: string,
  //   env?: Record<string, string>,
  // ): {
  //   default_registry_url: string;
  //   default_registry_token: string;
  //   default_registry_username: string;
  //   default_registry_password: string;
  // } => $bindgenFn("InternalTesting.schema.zig", "loadNpmrc")(src, env),
  loadNpmrc: $bindgenFn("InternalTesting.schema.zig", "loadNpmrc"),
};

export const cssInternals = {
  minifyTestWithOptions: $bindgenFn("InternalTesting.schema.zig", "cssMinifyTestWithOptions"),
  minifyErrorTestWithOptions: $bindgenFn("InternalTesting.schema.zig", "cssMinifyErrorTestWithOptions"),
  testWithOptions: $bindgenFn("InternalTesting.schema.zig", "cssTestWithOptions"),
  prefixTestWithOptions: $bindgenFn("InternalTesting.schema.zig", "cssPrefixTestWithOptions"),
  minifyTest: $bindgenFn("InternalTesting.schema.zig", "cssMinifyTest"),
  prefixTest: $bindgenFn("InternalTesting.schema.zig", "cssPrefixTest"),
  _test: $bindgenFn("InternalTesting.schema.zig", "cssTest"),
  attrTest: $bindgenFn("InternalTesting.schema.zig", "cssAttrTest"),
};

export const crash_handler = {
  getMachOImageZeroOffset: $bindgenFn("crash_handler_jsc.schema.zig", "getMachOImageZeroOffset"),
  getFeaturesAsVLQ: $bindgenFn("crash_handler_jsc.schema.zig", "getFeaturesAsVLQ"),
  getFeatureData: $bindgenFn("crash_handler_jsc.schema.zig", "getFeatureData"),
  segfault: $bindgenFn("crash_handler_jsc.schema.zig", "segfault"),
  panic: $bindgenFn("crash_handler_jsc.schema.zig", "panic"),
  rootError: $bindgenFn("crash_handler_jsc.schema.zig", "rootError"),
  outOfMemory: $bindgenFn("crash_handler_jsc.schema.zig", "outOfMemory"),
  raiseIgnoringPanicHandler: $bindgenFn("crash_handler_jsc.schema.zig", "raiseIgnoringPanicHandler"),
} as {
  getMachOImageZeroOffset: () => number;
  segfault: () => void;
  panic: () => void;
  rootError: () => void;
  outOfMemory: () => void;
  raiseIgnoringPanicHandler: () => void;
};

export const upgrade_test_helpers = {
  openTempDirWithoutSharingDelete: $bindgenFn("InternalTesting.schema.zig", "openTempDirWithoutSharingDelete"),
  closeTempDirHandle: $bindgenFn("InternalTesting.schema.zig", "closeTempDirHandle"),
} as {
  openTempDirWithoutSharingDelete: () => void;
  closeTempDirHandle: () => void;
};

const parseLockfileJSON = $bindgenFn("InternalTesting.schema.zig", "parseLockfile");
export const install_test_helpers = {
  parseLockfile: (cwd: string) => JSON.parse(parseLockfileJSON(cwd)),
} as {
  /**
   * Returns the lockfile at the given path as an object.
   */
  parseLockfile: (cwd: string) => any;
};

export const jscInternals = {
  isUTF16String: $bindgenFn("JSCTestingHelpers.schema.zig", "isUTF16String"),
  isLatin1String: $bindgenFn("JSCTestingHelpers.schema.zig", "isLatin1String"),
};

export const nativeFrameForTesting: (callback: () => void) => void = $bindgenFn(
  "CallSite.schema.zig",
  "callNativeFrameForTesting",
);

// Linux-only. Create an in-memory file descriptor with a preset size.
// You should call fs.closeSync(fd) when you're done with it.
export const memfd_create: (size: number) => number = $bindgenFn("InternalTesting.schema.zig", "createMemfd");

export const createStatsForIno: (ino: bigint, big: boolean) => any = $bindgenFn(
  "InternalTesting.schema.zig",
  "createStatsForIno",
);

export const setSyntheticAllocationLimitForTesting: (limit: number) => number = $bindgenFn(
  "InternalTesting.schema.zig",
  "setSyntheticAllocationLimit",
);

const parseManifestJSON = $bindgenFn("InternalTesting.schema.zig", "parseManifest");
export const npm_manifest_test_helpers = {
  parseManifest: (manifestFileName: string, registryUrl: string) =>
    JSON.parse(parseManifestJSON(manifestFileName, registryUrl)),
} as {
  /**
   * Returns the parsed manifest file. Currently only returns an array of available versions.
   */
  parseManifest: (manifestFileName: string, registryUrl: string) => any;
};

// Like npm-package-arg, sort of https://www.npmjs.com/package/npm-package-arg
export type Dependency = any;
export const npa: (name: string) => Dependency = $bindgenFn("InternalTesting.schema.zig", "dependencyFromJS");

export const npmTag: (
  name: string,
) => undefined | "npm" | "dist_tag" | "tarball" | "folder" | "symlink" | "workspace" | "git" | "github" | "catalog" =
  $bindgenFn("InternalTesting.schema.zig", "inferDependencyTag");

export const readTarball: (tarball: string) => any = $bindgenFn("InternalTesting.schema.zig", "readTarball");

export const isArchitectureMatch: (architecture: string[]) => boolean = $bindgenFn(
  "InternalTesting.schema.zig",
  "architectureIsMatch",
);

export const isOperatingSystemMatch: (operatingSystem: string[]) => boolean = $bindgenFn(
  "InternalTesting.schema.zig",
  "operatingSystemIsMatch",
);

export const createSocketPair: () => [number, number] = $bindgenFn("InternalTesting.schema.zig", "createSocketPair");

export const isModuleResolveFilenameSlowPathEnabled: () => boolean = $bindgenFn(
  "NodeModuleModule.schema.zig",
  "isResolveFilenameSlowPathEnabled",
);

export const frameworkRouterInternals = {
  parseRoutePattern: $bindgenFn("FrameworkFileSystemRouter.schema.zig", "parseRoutePattern"),
  FrameworkRouter: $bindgenClass("FrameworkFileSystemRouter.schema.zig", "FrameworkFileSystemRouter"),
} as {
  parseRoutePattern: (style: string, pattern: string) => null | { kind: string; pattern: string };
  FrameworkRouter: {
    new (opts: any): any;
  };
};

export type BindgenTestMode = "fast" | "safe-mode" | "unicode-😀";
export type BindgenTestScalar = number | string | boolean;

export type BindgenTestMetadata = {
  mode: BindgenTestMode;
  note?: string;
};

export type BindgenTestOptions = {
  count: number;
  label?: string;
  enabled?: boolean;
  metadata: BindgenTestMetadata;
  bytes?: ArrayBufferView;
};

export type BindgenTestBundle = {
  metadata: BindgenTestMetadata;
  scalars: readonly BindgenTestScalar[];
  lookup: Record<string, BindgenTestScalar>;
};

export type BindgenCallbackComposite = {
  choice: InstanceType<typeof bindgen.Counter> | number;
  labels: string[];
  value: unknown;
  observer: () => void;
  label: string;
};

type BindgenCallbackRecord = Record<string, { callback: () => number; bytes: Uint8Array }>;

export const bindgen = {
  add: $bindgenFn("bindgen_test.schema.zig", "add"),
  echoInt8: $bindgenFn("bindgen_test.schema.zig", "echoInt8"),
  echoInt16: $bindgenFn("bindgen_test.schema.zig", "echoInt16"),
  echoUint16: $bindgenFn("bindgen_test.schema.zig", "echoUint16"),
  echoUint32: $bindgenFn("bindgen_test.schema.zig", "echoUint32"),
  echoInt64: $bindgenFn("bindgen_test.schema.zig", "echoInt64"),
  echoUint64: $bindgenFn("bindgen_test.schema.zig", "echoUint64"),
  echoTestOptions: $bindgenFn("bindgen_test.schema.zig", "echoTestOptions"),
  echoDictionarySource: $bindgenFn("bindgen_test.schema.zig", "echoDictionarySource"),
  echoTestScalars: $bindgenFn("bindgen_test.schema.zig", "echoTestScalars"),
  roundTripTestBundle: $bindgenFn("bindgen_test.schema.zig", "roundTripTestBundle"),
  visitTestBundle: $bindgenFn("bindgen_test.schema.zig", "visitTestBundle"),
  dispatchAdvanced: $bindgenFn("bindgen_test.schema.zig", "dispatchAdvanced"),
  inspectNodeConversionOrder: $bindgenFn("bindgen_test.schema.zig", "inspectNodeConversionOrder"),
  inspectCustomConverters: $bindgenFn("bindgen_test.schema.zig", "inspectCustomConverters"),
  inspectLazyOptions: $bindgenFn("bindgen_test.schema.zig", "inspectLazyOptions"),
  inspectLazyConvertedLabel: $bindgenFn("bindgen_test.schema.zig", "inspectLazyConvertedLabel"),
  inspectLazyReceiverIndex: $bindgenFn("bindgen_test.schema.zig", "inspectLazyReceiverIndex"),
  inspectLazyRestLease: $bindgenFn("bindgen_test.schema.zig", "inspectLazyRestLease"),
  retryLazyString: $bindgenFn("bindgen_test.schema.zig", "retryLazyString"),
  retryCppLazyString: $bindgenFn("bindgen_test.schema.zig", "retryCppLazyString"),
  callbackIdentityAfterReentry: $bindgenFn("bindgen_test.schema.zig", "callbackIdentityAfterReentry"),
  visitGCEntries: $bindgenFn("bindgen_test.schema.zig", "visitGCEntries"),
  visitDeferredGCEntries: $bindgenFn("bindgen_test.schema.zig", "visitDeferredGCEntries"),
  leaseWithIgnoredOperand: $bindgenFn("bindgen_test.schema.zig", "leaseWithIgnoredOperand"),
  inspectNestedLazyFields: $bindgenFn("bindgen_test.schema.zig", "inspectNestedLazyFields"),
  inspectEagerLazyFields: $bindgenFn("bindgen_test.schema.zig", "inspectEagerLazyFields"),
  inspectNestedLazyRest: $bindgenFn("bindgen_test.schema.zig", "inspectNestedLazyRest"),
  forceLazyPath: $bindgenFn("bindgen_test.schema.zig", "forceLazyPath"),
  describePatternValues: $bindgenFn("bindgen_test.schema.zig", "describePatternValues"),
  requiredAndOptionalArg: $bindgenFn("bindgen_test.schema.zig", "requiredAndOptionalArg"),
  domStringLength: $bindgenFn("bindgen_test.schema.zig", "domStringLength"),
  isolateEngineString: $bindgenFn("bindgen_test.schema.zig", "isolateEngineString"),
  echoDOMString: $bindgenFn("bindgen_test.schema.zig", "echoDOMString"),
  echoUSVString: $bindgenFn("bindgen_test.schema.zig", "echoUSVString"),
  echoByteString: $bindgenFn("bindgen_test.schema.zig", "echoByteString"),
  strictUSVString: $bindgenFn("bindgen_test.schema.zig", "strictUSVString"),
  strictByteString: $bindgenFn("bindgen_test.schema.zig", "strictByteString"),
  echoBuffer: $bindgenFn("bindgen_test.schema.zig", "echoBuffer"),
  fillMutableLease: $bindgenFn("bindgen_test.schema.zig", "fillMutableLease"),
  setMutableLeaseByte: $bindgenFn("bindgen_test.schema.zig", "setMutableLeaseByte"),
  inspectInt32FromJS: $bindgenFn("bindgen_test.schema.zig", "inspectInt32FromJS"),
  inspectLeaseOptionsFromJS: $bindgenFn("bindgen_test.schema.zig", "inspectLeaseOptionsFromJS"),
  inspectLeaseAfterCallback: $bindgenFn("bindgen_test.schema.zig", "inspectLeaseAfterCallback"),
  inspectNestedLeaseAfterCallback: $bindgenFn("bindgen_test.schema.zig", "inspectNestedLeaseAfterCallback"),
  echoNullableBuffer: $bindgenFn("bindgen_test.schema.zig", "echoNullableBuffer"),
  echoAny: $bindgenFn("bindgen_test.schema.zig", "echoAny"),
  snapshotStoredRoots: $bindgenFn("bindgen_test.schema.zig", "snapshotStoredRoots"),
  preserveTransferredRoot: $bindgenFn("bindgen_test.schema.zig", "preserveTransferredRoot"),
  readIndexViaEngine: $bindgenFn("bindgen_test.schema.zig", "readIndexViaEngine"),
  engineBufferSequenceLengthViaEngine: $bindgenFn("bindgen_test.schema.zig", "engineBufferSequenceLengthViaEngine"),
  nodePathLengthViaEngine: $bindgenFn("bindgen_test.schema.zig", "nodePathLengthViaEngine"),
  invocationThis: $bindgenFn("bindgen_test.schema.zig", "invocationThis"),
  invokeCallback: $bindgenFn("bindgen_test.schema.zig", "invokeCallback"),
  invokeOwnedCallback: $bindgenFn("bindgen_test.schema.zig", "invokeOwnedCallback"),
  scheduleCallback: $bindgenFn("bindgen_test.schema.zig", "scheduleCallback"),
  echoCallback: $bindgenFn("bindgen_test.schema.zig", "echoCallback"),
  invokeStringCallback: $bindgenFn("bindgen_test.schema.zig", "invokeStringCallback"),
  invokeNullableStringCallback: $bindgenFn("bindgen_test.schema.zig", "invokeNullableStringCallback"),
  invokeBufferCallback: $bindgenFn("bindgen_test.schema.zig", "invokeBufferCallback"),
  invokeAnyCallback: $bindgenFn("bindgen_test.schema.zig", "invokeAnyCallback"),
  invokeCompositeCallback: $bindgenFn("bindgen_test.schema.zig", "invokeCompositeCallback"),
  retainCallbackRecord: $bindgenFn("bindgen_test.schema.zig", "retainCallbackRecord"),
  inspectCallbackRecordViews: $bindgenFn("bindgen_test.schema.zig", "inspectCallbackRecordViews"),
  invokeRestCallback: $bindgenFn("bindgen_test.schema.zig", "invokeRestCallback"),
  invokeTypedRestCallback: $bindgenFn("bindgen_test.schema.zig", "invokeTypedRestCallback"),
  invokeCallbackFactory: $bindgenFn("bindgen_test.schema.zig", "invokeCallbackFactory"),
  invokeObserver: $bindgenFn("bindgen_test.schema.zig", "invokeObserver"),
  invokeIntegerCallback: $bindgenFn("bindgen_test.schema.zig", "invokeIntegerCallback"),
  clampInteger: $bindgenFn("bindgen_test.schema.zig", "clampInteger"),
  validateInteger: $bindgenFn("bindgen_test.schema.zig", "validateInteger"),
  validateNodeBoolean: $bindgenFn("bindgen_test.schema.zig", "validateNodeBoolean"),
  validateNodeNumber: $bindgenFn("bindgen_test.schema.zig", "validateNodeNumber"),
  validateNodeString: $bindgenFn("bindgen_test.schema.zig", "validateNodeString"),
  validateNodeStrings: $bindgenFn("bindgen_test.schema.zig", "validateNodeStrings"),
  defaultString: $bindgenFn("bindgen_test.schema.zig", "defaultString"),
  defaultAny: $bindgenFn("bindgen_test.schema.zig", "defaultAny"),
  classifyPresence: $bindgenFn("bindgen_test.schema.zig", "classifyPresence"),
  inspectRest: $bindgenFn("bindgen_test.schema.zig", "inspectRest"),
  inspectStringRest: $bindgenFn("bindgen_test.schema.zig", "inspectStringRest"),
  inspectBrandedRest: $bindgenFn("bindgen_test.schema.zig", "inspectBrandedRest"),
  cppInspectStringRest: $bindgenFn("bindgen_test.schema.zig", "cppInspectStringRest"),
  echoStringRest: $bindgenFn("bindgen_test.schema.zig", "echoStringRest"),
  echoBufferRest: $bindgenFn("bindgen_test.schema.zig", "echoBufferRest"),
  echoAggregateRest: $bindgenFn("bindgen_test.schema.zig", "echoAggregateRest"),
  echoNullableInt: $bindgenFn("bindgen_test.schema.zig", "echoNullableInt"),
  classifyNullablePresence: $bindgenFn("bindgen_test.schema.zig", "classifyNullablePresence"),
  echoNullableString: $bindgenFn("bindgen_test.schema.zig", "echoNullableString"),
  echoNullableAny: $bindgenFn("bindgen_test.schema.zig", "echoNullableAny"),
  readCounterValue: $bindgenFn("bindgen_test.schema.zig", "readCounterValue"),
  inspectCounterWrapperHandles: $bindgenFn("bindgen_test.schema.zig", "inspectCounterWrapperHandles"),
  readSharedCounterValue: $bindgenFn("bindgen_test.schema.zig", "readSharedCounterValue"),
  domainError: $bindgenFn("bindgen_test.schema.zig", "domainError"),
  asyncResult: $bindgenFn("bindgen_test.schema.zig", "asyncResult"),
  asyncEcho: $bindgenFn("bindgen_test.schema.zig", "asyncEcho"),
  asyncUTF8Strings: $bindgenFn("bindgen_test.schema.zig", "asyncUTF8Strings"),
  asyncMaterialized: $bindgenFn("bindgen_test.schema.zig", "asyncMaterialized"),
  asyncWeakEcho: $bindgenFn("bindgen_test.schema.zig", "asyncWeakEcho"),
  asyncPendingEcho: $bindgenFn("bindgen_test.schema.zig", "asyncPendingEcho"),
  setTransferAllocationFailureCountdown: $bindgenFn("bindgen_test.schema.zig", "setTransferAllocationFailureCountdown"),
  setWeakAllocationFailureCountdown: $bindgenFn("bindgen_test.schema.zig", "setWeakAllocationFailureCountdown"),
  setRootAllocationFailureCountdown: $bindgenFn("bindgen_test.schema.zig", "setRootAllocationFailureCountdown"),
  sumIntegerWidthsViaEngine: $bindgenFn("bindgen_test.schema.zig", "sumIntegerWidthsViaEngine"),
  Counter: $bindgenClass("bindgen_test.schema.zig", "Counter"),
  ScaledCounter: $bindgenClass("bindgen_test.schema.zig", "ScaledCounter"),
  SharedCounter: $bindgenClass("bindgen_test.schema.zig", "SharedCounter"),
  SharedScaledCounter: $bindgenClass("bindgen_test.schema.zig", "SharedScaledCounter"),
  CloneBox: $bindgenClass("bindgen_test.schema.zig", "CloneBox"),
} as {
  add: (a: any, b: any) => number;
  echoInt8: (input: unknown) => number;
  echoInt16: (input: unknown) => number;
  echoUint16: (input: unknown) => number;
  echoUint32: (input: unknown) => number;
  echoInt64: (input: unknown) => number;
  echoUint64: (input: unknown) => number;
  echoTestOptions: (options: BindgenTestOptions) => BindgenTestOptions;
  echoDictionarySource: (input: { trigger?: string } | null | undefined) => unknown;
  echoTestScalars: (input: readonly BindgenTestScalar[]) => readonly BindgenTestScalar[];
  roundTripTestBundle: (input: BindgenTestBundle) => BindgenTestBundle;
  dispatchAdvanced: {
    (input: ArrayBufferView, label: string): number;
    (input: Iterable<number> | null, label: string, trigger?: () => void): number;
    (input: BindgenTestOptions, label: string, trigger?: () => void): number;
  };
  inspectCustomConverters: (
    numbers: unknown,
    nullableLabel: string | null,
    optionalLabel?: string,
    defaultLabel?: string,
  ) => number;
  inspectLazyOptions: (input: BindgenTestOptions, shouldConvert: boolean) => number;
  inspectLazyConvertedLabel: (input: string) => number;
  inspectLazyReceiverIndex: (this: ArrayBufferView, index: number, trigger: () => void) => number;
  inspectLazyRestLease: (
    bytes: ArrayBufferView,
    trigger: () => void,
    discardLast: boolean,
    ...values: unknown[]
  ) => number;
  retryLazyString: (input: unknown) => number;
  retryCppLazyString: (input: unknown) => number;
  callbackIdentityAfterReentry: (first: () => void, second: () => void, changeContext: () => void) => boolean;
  visitGCEntries: (
    entries: { value: unknown; callback: (value: unknown) => number; bytes: ArrayBufferView }[],
    trigger: unknown,
  ) => number;
  visitDeferredGCEntries: (
    entries: { value: unknown; callback: (value: unknown) => number; bytes: ArrayBufferView }[],
    trigger: unknown,
    ignored?: unknown,
  ) => number;
  leaseWithIgnoredOperand: (input: ArrayBufferView, ignored: unknown, before?: unknown) => number;
  inspectNestedLazyFields: (input: unknown, bytes: ArrayBufferView, trigger: () => void) => number;
  inspectEagerLazyFields: (input: unknown, bytes: ArrayBufferView) => number;
  inspectNestedLazyRest: (...values: unknown[]) => number;
  forceLazyPath: (options: unknown, absolute: boolean) => number;
  describePatternValues: (values: unknown[]) => string;
  visitTestBundle: (input: BindgenTestBundle, visitor: (bundle: BindgenTestBundle) => number) => number;
  requiredAndOptionalArg: (a: any, b?: any, c?: any, d?: any) => number;
  domStringLength: (input: any) => number;
  isolateEngineString: (input: string, fail: boolean) => string;
  echoDOMString: (input: any) => string;
  echoUSVString: (input: any) => string;
  echoByteString: (input: any) => string;
  strictUSVString: (input: unknown) => string;
  strictByteString: (input: unknown) => string;
  echoBuffer: (input: any) => Uint8Array;
  inspectLeaseOptionsFromJS: (input: { bytes: ArrayBufferView; marker: unknown }) => number;
  inspectInt32FromJS: (input: unknown) => number;
  inspectLeaseAfterCallback: (input: ArrayBufferView, callback: (length: number) => void) => number;
  inspectNestedLeaseAfterCallback: (input: ArrayBufferView | string, callback: (length: number) => void) => number;
  echoNullableBuffer: (input: ArrayBufferView | null) => Uint8Array | null;
  echoAny: (input: unknown) => unknown;
  preserveTransferredRoot: <T extends object>(input: T, collect: () => void) => T;
  setRootAllocationFailureCountdown: (countdown: number) => void;
  snapshotStoredRoots: (
    input: unknown,
    replacement: unknown,
    engine: unknown,
    promise: Promise<unknown>,
    collect: () => void,
    failAfter?: number,
  ) => {
    root: unknown;
    optional: unknown;
    engine: unknown;
    promise: Promise<unknown>;
    replacement: unknown;
    cleared: boolean;
    reused: boolean;
  };
  readIndexViaEngine: (target: unknown, index: number) => unknown;
  engineBufferSequenceLengthViaEngine: () => number;
  nodePathLengthViaEngine: (input: string) => number;
  invocationThis(this: unknown): unknown;
  invokeIntegerCallback: (
    callback: (
      signed8: number,
      signed16: number,
      unsigned16: number,
      unsigned32: number,
      signed64: number,
      unsigned64: number,
    ) => number,
    signed8: number,
    signed16: number,
    unsigned16: number,
    unsigned32: number,
    signed64: number,
    unsigned64: number,
  ) => number;
  invokeNullableStringCallback: (
    callback: (input: string | null) => string | null,
    input: string | null,
  ) => string | null;
  invokeCompositeCallback: (callback: () => BindgenCallbackComposite) => BindgenCallbackComposite;
  retainCallbackRecord: (factory: () => BindgenCallbackRecord) => BindgenCallbackRecord;
  inspectCallbackRecordViews: (factory: () => BindgenCallbackRecord, failAfter?: number) => number;
  invokeRestCallback: (
    callback: (prefix: number, ...values: unknown[]) => number,
    prefix: number,
    ...values: unknown[]
  ) => number;
  invokeTypedRestCallback: (
    callback: (prefix: number, ...values: number[]) => number,
    prefix: number,
    ...values: number[]
  ) => number;
  clampInteger: (input: any) => number;
  validateInteger: (input: any) => number;
  defaultString: (input?: any) => string;
  defaultAny: (input?: unknown) => unknown;
  classifyPresence: (input?: unknown) => string;
  inspectRest: (prefix: number, ...values: unknown[]) => number;
  inspectStringRest: (...values: unknown[]) => number;
  inspectBrandedRest: (...values: unknown[]) => number;
  cppInspectStringRest: (...values: unknown[]) => number;
  echoStringRest: (...values: unknown[]) => (string | null)[];
  echoBufferRest: (callback: () => void, ...values: (ArrayBufferView | ArrayBuffer | null)[]) => (Uint8Array | null)[];
  echoAggregateRest: (...values: { label: string; value: string | number | boolean }[]) => {
    label: string;
    value: string | number | boolean;
  }[];
  echoNullableInt: (input: number | null) => number | null;
  classifyNullablePresence: (input?: number | null) => number;
  echoNullableString: (input: string | null) => string | null;
  echoNullableAny: (input: unknown | null) => unknown | null;
  readCounterValue: (value: unknown) => number;
  readSharedCounterValue: (value: unknown) => number;
  domainError: (kind: number, message: string) => number;
  asyncResult: (kind: number, message: string) => Promise<number>;
  asyncEcho: (message: string) => Promise<string>;
  asyncMaterialized: (value: number, label: unknown) => Promise<{ value: number; label: unknown }>;
  asyncWeakEcho: (kind: number, message: string) => Promise<string>;
  asyncPendingEcho: (message: string) => Promise<string>;
  sumIntegerWidthsViaEngine: (
    signed8: number,
    signed16: number,
    unsigned16: number,
    unsigned32: number,
    signed64: number,
    unsigned64: number,
  ) => number;
  Counter: {
    new (initial?: number): {
      increment(delta?: number): number;
      sum(value: number): number;
      sum(left: number, right: number): number;
      incrementViaBuiltin(delta: number): number;
      incrementViaCpp(delta: number): number;
      readonly doubledViaBuiltin: number;
      setCachedCallback(callback: () => void): void;
      invokeCachedCallback(): void;
      value: number;
      readonly newTarget: unknown;
      cached: unknown;
      cachedCallback: (() => void) | undefined;
      cachedString: string | null;
    };
    kind(): string;
    defaultValue: number;
  };
  ScaledCounter: {
    new (
      initial?: number,
      factor?: number,
    ): {
      increment(delta?: number): number;
      sum(value: number): number;
      sum(left: number, right: number): number;
      scale(): number;
      value: number;
      readonly factor: number;
      readonly newTarget: unknown;
      cached: unknown;
      scaledCached: unknown;
    };
    kind(): string;
    defaultValue: number;
  };
  SharedCounter: {
    new (initial?: number): {
      increment(delta?: number): number;
      incrementAsync(delta: number): Promise<number>;
      readonly value: number;
    };
    identity(value: unknown): unknown;
    holdForRealmTest(value: unknown): void;
    heldForRealmTest(): unknown;
    releaseForRealmTest(): void;
    releaseHeldOffThreadForTest(): void;
    readonly destroyedCount: number;
  };
};

export const bindgenBuiltinAdd: (a: unknown, b: unknown) => number = $bindgenFn(
  "bindgen_test.schema.zig",
  "builtinAdd",
);
export const bindgenCppAdd: (a: unknown, b: unknown) => number = $bindgenFn("bindgen_test.schema.zig", "cppAdd");
export const bindgenCppOverload: {
  (value: number): number;
  (value: string): number;
} = $bindgenFn("bindgen_test.schema.zig", "cppOverload");
export const bindgenCppEchoString: (input: unknown) => string = $bindgenFn("bindgen_test.schema.zig", "cppEchoString");
export const bindgenCppLazyStringLength: (input: unknown, convert: boolean) => number = $bindgenFn(
  "bindgen_test.schema.zig",
  "cppLazyStringLength",
);
export const bindgenCppBufferLength: (input: unknown) => number = $bindgenFn(
  "bindgen_test.schema.zig",
  "cppBufferLength",
);
export const bindgenCppDictionarySourceSequenceLength: (input: object[]) => number = $bindgenFn(
  "bindgen_test.schema.zig",
  "cppDictionarySourceSequenceLength",
);
export const bindgenCppExternalRefPresent: (input: AbortSignal) => boolean = $bindgenFn(
  "bindgen_test.schema.zig",
  "cppExternalRefPresent",
);
export const bindgenCppExternalRefSequenceLength: (input: AbortSignal[]) => number = $bindgenFn(
  "bindgen_test.schema.zig",
  "cppExternalRefSequenceLength",
);
export const bindgenCppOptionalUnionPresent: (input: string | number | undefined) => boolean = $bindgenFn(
  "bindgen_test.schema.zig",
  "cppOptionalUnionPresent",
);
export const bindgenCppClassifyNullablePresence: (input?: number | null) => number = $bindgenFn(
  "bindgen_test.schema.zig",
  "cppClassifyNullablePresence",
);
export const bindgenCppClassifyNullableFieldPresence: (options: { input?: number | null }) => number = $bindgenFn(
  "bindgen_test.schema.zig",
  "cppClassifyNullableFieldPresence",
);
export const bindgenCppInspectRest: (prefix: number, ...values: unknown[]) => number = $bindgenFn(
  "bindgen_test.schema.zig",
  "cppInspectRest",
);
export const bindgenCppEchoBuffer: (input: ArrayBufferView) => Uint8Array = $bindgenFn(
  "bindgen_test.schema.zig",
  "cppEchoBuffer",
);
export const bindgenCppSumIntegerWidths: (
  signed8: number,
  signed16: number,
  unsigned16: number,
  unsigned32: number,
  signed64: number,
  unsigned64: number,
) => number = $bindgenFn("bindgen_test.schema.zig", "cppSumIntegerWidths");
export const bindgenCppCallZigExport: (a: number, b: number, bias: number) => number = $bindgenFn(
  "bindgen_test.schema.zig",
  "cppCallZigExport",
);
export const bindgenCppCallZigNativeString: (label: string, input: ArrayBufferView) => string = $bindgenFn(
  "bindgen_test.schema.zig",
  "cppCallZigNativeString",
);

export const bindgenCppCallZigNativeRecord: (
  factory: () => () => number,
  input: ArrayBufferView,
) => Record<string, { callback: () => number; bytes: Uint8Array }> = $bindgenFn(
  "bindgen_test.schema.zig",
  "cppCallZigNativeRecord",
);

export const noOpForTesting = {
  __proto__: null,
  function: $bindgenFn("NoOpForTesting.schema.zig", "noop"),
  callback: $bindgenFn("NoOpForTesting.schema.zig", "callback"),
  get getterSetter() {
    return undefined;
  },
  set getterSetter(_) {},
};
export const Dequeue = require("internal/fifo");
export const linearFifoOrderedRemoveProbe: (scenario: 0 | 1) => number[] = $bindgenFn(
  "InternalTesting.schema.zig",
  "linearFifoOrderedRemoveProbe",
);

export const fs = require("node:fs/promises").$data;

export const fsStreamInternals = {
  writeStreamFastPath(str) {
    return str[require("internal/fs/streams").kWriteStreamFastPath];
  },
};

export const arrayBufferViewHasBuffer = $bindgenFn("bindgen_test.schema.zig", "arrayBufferViewHasBuffer");

export const timerInternals = {
  timerClockMs: $bindgenFn("InternalTesting.schema.zig", "timerClockMs"),
};

export const decodeURIComponentSIMD = $bindgenFn("bindgen_test.schema.zig", "decodeURIComponentSIMD");

export const getDevServerDeinitCount = $bindgenFn("DevServer.schema.zig", "getDeinitCountForTesting");
export const fileWatcherStartWithUnavailableIo: () => string = $bindgenFn(
  "InternalTesting.schema.zig",
  "fileWatcherStartWithUnavailableIo",
);
export const getCounters = $bindgenFn("InternalTesting.schema.zig", "createCountersObject");
export const hasNonReifiedStatic = $bindgenFn("bindgen_test.schema.zig", "hasNonReifiedStatic");

interface setSocketOptionsFn {
  (socket: Bun.Socket, sendBuffer: 1, size: number): void;
  (socket: Bun.Socket, recvBuffer: 2, size: number): void;
}

export const setSocketOptions: setSocketOptionsFn = $bindgenFn("InternalTesting.schema.zig", "setSocketOptions");
type SerializationContext = "worker" | "window" | "postMessage" | "default";
export const structuredCloneAdvanced: (
  value: any,
  transferList: Iterable<object>,
  forTransfer: boolean,
  forStorage: boolean,
  serializationContext?: SerializationContext,
) => any = $bindgenFn("bindgen_test.schema.zig", "structuredCloneAdvanced");

export const lsanDoLeakCheck = $bindgenFn("bindgen_test.schema.zig", "lsanDoLeakCheck");

export const getEventLoopStats: () => { activeTasks: number; concurrentRef: number; numPolls: number } = $bindgenFn(
  "InternalTesting.schema.zig",
  "getActiveTasks",
);

export const hostedGitInfo = {
  parseUrl: $bindgenFn("InternalTesting.schema.zig", "hostedGitParseUrl"),
  fromUrl: $bindgenFn("InternalTesting.schema.zig", "hostedGitFromUrl"),
};

export const translateUVErrorToE: (code: number) => string | undefined = $bindgenFn(
  "InternalTesting.schema.zig",
  "translateUVErrorToE",
);

export const translateNtStatusToE: (code: number) => string | undefined = $bindgenFn(
  "InternalTesting.schema.zig",
  "translateNtStatusToE",
);

export const sysErrorNameFromLibuv: (errno: number) => string | undefined = $bindgenFn(
  "InternalTesting.schema.zig",
  "sysErrorNameFromLibuv",
);

export const sigactionLayout: () =>
  | undefined
  | {
      installed: { handler: number; flags: number };
      readback: { handler: number; flags: number };
      sizeof: number;
    } = $bindgenFn("InternalTesting.schema.zig", "sigactionLayout");

export const BunString_toThreadSafeRefCountDelta: () => number = $bindgenFn(
  "InternalTesting.schema.zig",
  "BunString_toThreadSafeRefCountDelta",
);

export const stringsInternals = {
  /**
   * Calls `bun.strings.toUTF16AllocForReal(allocator, bytes, false, true)` and
   * returns the resulting UTF-16 data as a JS string. The `sentinel = true`
   * path is otherwise only reachable from Windows `bun build --compile`
   * metadata, so this binding lets us exercise it on all platforms.
   */
  toUTF16AllocSentinel: $bindgenFn("InternalTesting.schema.zig", "toUTF16AllocSentinel") as (
    bytes: Uint8Array,
  ) => string,
};

export const fetchH2Internals = {
  liveCounts: $bindgenFn("InternalTesting.schema.zig", "h2LiveCounts") as () => {
    sessions: number;
    streams: number;
  },
};

export const fetchH3Internals = {
  liveCounts: $bindgenFn("InternalTesting.schema.zig", "h3LiveCounts") as () => {
    sessions: number;
    streams: number;
  },
};

export const fileSinkInternals = {
  liveCount: $bindgenFn("InternalTesting.schema.zig", "fileSinkLiveCount") as () => number,
};
