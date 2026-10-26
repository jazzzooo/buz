import type { ByteBuffer } from "peechy/bb";

type byte = number;
type float = number;
type int = number;
type alphanumeric = string;
type uint = number;
type int8 = number;
type uint8 = number;
type lowp = number;
type int16 = number;
type int32 = number;
type float32 = number;
type uint16 = number;
type uint32 = number;
export const enum Loader {
  jsx = 1,
  js = 2,
  ts = 3,
  tsx = 4,
  css = 5,
  file = 6,
  json = 7,
  jsonc = 8,
  toml = 9,
  wasm = 10,
  napi = 11,
  base64 = 12,
  dataurl = 13,
  text = 14,
  bunsh = 15,
  sqlite = 16,
  sqlite_embedded = 17,
  html = 18,
  yaml = 19,
  json5 = 20,
  md = 21,
}
export const LoaderKeys: {
  1: "jsx";
  2: "js";
  3: "ts";
  4: "tsx";
  5: "css";
  6: "file";
  7: "json";
  8: "jsonc";
  9: "toml";
  10: "wasm";
  11: "napi";
  12: "base64";
  13: "dataurl";
  14: "text";
  15: "bunsh";
  16: "sqlite";
  17: "sqlite_embedded";
  18: "html";
  19: "yaml";
  20: "json5";
  21: "md";
  jsx: "jsx";
  js: "js";
  ts: "ts";
  tsx: "tsx";
  css: "css";
  file: "file";
  json: "json";
  jsonc: "jsonc";
  toml: "toml";
  wasm: "wasm";
  napi: "napi";
  base64: "base64";
  dataurl: "dataurl";
  text: "text";
  bunsh: "bunsh";
  sqlite: "sqlite";
  sqlite_embedded: "sqlite_embedded";
  html: "html";
  yaml: "yaml";
  json5: "json5";
  md: "md";
};
export const enum StackFrameScope {
  Eval = 1,
  Module = 2,
  Function = 3,
  Global = 4,
  Wasm = 5,
  Constructor = 6,
}
export const StackFrameScopeKeys: {
  1: "Eval";
  Eval: "Eval";
  2: "Module";
  Module: "Module";
  3: "Function";
  Function: "Function";
  4: "Global";
  Global: "Global";
  5: "Wasm";
  Wasm: "Wasm";
  6: "Constructor";
  Constructor: "Constructor";
};
export const enum FallbackStep {
  ssr_disabled = 1,
  create_vm = 2,
  configure_router = 3,
  configure_defines = 4,
  resolve_entry_point = 5,
  load_entry_point = 6,
  eval_entry_point = 7,
  fetch_event_handler = 8,
}
export const FallbackStepKeys: {
  1: "ssr_disabled";
  ssr_disabled: "ssr_disabled";
  2: "create_vm";
  create_vm: "create_vm";
  3: "configure_router";
  configure_router: "configure_router";
  4: "configure_defines";
  configure_defines: "configure_defines";
  5: "resolve_entry_point";
  resolve_entry_point: "resolve_entry_point";
  6: "load_entry_point";
  load_entry_point: "load_entry_point";
  7: "eval_entry_point";
  eval_entry_point: "eval_entry_point";
  8: "fetch_event_handler";
  fetch_event_handler: "fetch_event_handler";
};
export const enum ResolveMode {
  disable = 1,
  lazy = 2,
  dev = 3,
  bundle = 4,
}
export const ResolveModeKeys: {
  1: "disable";
  disable: "disable";
  2: "lazy";
  lazy: "lazy";
  3: "dev";
  dev: "dev";
  4: "bundle";
  bundle: "bundle";
};
export const enum Target {
  browser = 1,
  node = 2,
  bun = 3,
  bun_macro = 4,
}
export const TargetKeys: {
  1: "browser";
  browser: "browser";
  2: "node";
  node: "node";
  3: "bun";
  bun: "bun";
  4: "bun_macro";
  bun_macro: "bun_macro";
};
export const enum CSSInJSBehavior {
  facade = 1,
  facade_onimportcss = 2,
  auto_onimportcss = 3,
}
export const CSSInJSBehaviorKeys: {
  1: "facade";
  facade: "facade";
  2: "facade_onimportcss";
  facade_onimportcss: "facade_onimportcss";
  3: "auto_onimportcss";
  auto_onimportcss: "auto_onimportcss";
};
export const enum JSXRuntime {
  automatic = 1,
  classic = 2,
  solid = 3,
}
export const JSXRuntimeKeys: {
  1: "automatic";
  automatic: "automatic";
  2: "classic";
  classic: "classic";
  3: "solid";
  solid: "solid";
};
export const enum DotEnvBehavior {
  disable = 1,
  prefix = 2,
  load_all = 3,
  load_all_without_inlining = 4,
}
export const DotEnvBehaviorKeys: {
  1: "disable";
  disable: "disable";
  2: "prefix";
  prefix: "prefix";
  3: "load_all";
  load_all: "load_all";
  4: "load_all_without_inlining";
  load_all_without_inlining: "load_all_without_inlining";
};
export const enum SourceMapMode {
  inline_into_file = 1,
  external = 2,
}
export const SourceMapModeKeys: {
  1: "inline_into_file";
  inline_into_file: "inline_into_file";
  2: "external";
  external: "external";
};
export const enum ImportKind {
  entry_point = 1,
  stmt = 2,
  require = 3,
  dynamic = 4,
  require_resolve = 5,
  at = 6,
  url = 7,
  internal = 8,
}
export const ImportKindKeys: {
  1: "entry_point";
  entry_point: "entry_point";
  2: "stmt";
  stmt: "stmt";
  3: "require";
  require: "require";
  4: "dynamic";
  dynamic: "dynamic";
  5: "require_resolve";
  require_resolve: "require_resolve";
  6: "at";
  at: "at";
  7: "url";
  url: "url";
  8: "internal";
  internal: "internal";
};
export const enum TransformResponseStatus {
  success = 1,
  fail = 2,
}
export const TransformResponseStatusKeys: {
  1: "success";
  success: "success";
  2: "fail";
  fail: "fail";
};
export const enum MessageLevel {
  err = 1,
  warn = 2,
  note = 3,
  info = 4,
  debug = 5,
}
export const MessageLevelKeys: {
  1: "err";
  err: "err";
  2: "warn";
  warn: "warn";
  3: "note";
  note: "note";
  4: "info";
  info: "info";
  5: "debug";
  debug: "debug";
};
export const enum TestKind {
  test_fn = 1,
  describe_fn = 2,
}
export const TestKindKeys: {
  1: "test_fn";
  test_fn: "test_fn";
  2: "describe_fn";
  describe_fn: "describe_fn";
};
export interface StackFrame {
  function_name: string;
  file: string;
  position: StackFramePosition;
  scope: StackFrameScope;
}

export interface StackFramePosition {
  line: int32;
  column: int32;
}

export interface SourceLine {
  line: int32;
  text: string;
}

export interface StackTrace {
  source_lines: SourceLine[];
  frames: StackFrame[];
}

export interface JSException {
  name?: string;
  message?: string;
  runtime_type?: uint16;
  code?: uint8;
  stack?: StackTrace;
}

export interface Problems {
  code: uint16;
  name: string;
  exceptions: JSException[];
  build: Log;
}

export interface Router {
  routes: StringMap;
  route: int32;
  params: StringMap;
}

export interface FallbackMessageContainer {
  message?: string;
  router?: Router;
  reason?: FallbackStep;
  problems?: Problems;
  cwd?: string;
}

export interface JSX {
  factory: string;
  runtime: JSXRuntime;
  fragment: string;
  development: boolean;
  import_source: string;
  react_fast_refresh: boolean;
}

export interface StringPointer {
  offset: uint32;
  length: uint32;
}

export interface StringMap {
  keys: string[];
  values: string[];
}

export interface LoaderMap {
  extensions: string[];
  loaders: Loader[];
}

export interface EnvConfig {
  prefix?: string;
  defaults?: StringMap;
}

export interface FrameworkConfig {
  package?: string;
  client?: FrameworkEntryPointMessage;
  server?: FrameworkEntryPointMessage;
  fallback?: FrameworkEntryPointMessage;
  development?: boolean;
  client_css_in_js?: CSSInJSBehavior;
  display_name?: string;
  overrideModules?: StringMap;
}

export interface FrameworkEntryPointMessage {
  path?: string;
  env?: EnvConfig;
}

export interface RouteConfig {
  dir?: string[];
  extensions?: string[];
  static_dir?: string;
  asset_prefix?: string;
}

export interface TransformOptions {
  jsx?: JSX;
  tsconfig_override?: string;
  resolve?: ResolveMode;
  origin?: string;
  absolute_working_dir?: string;
  define?: StringMap;
  preserve_symlinks?: boolean;
  entry_points?: string[];
  write?: boolean;
  inject?: string[];
  output_dir?: string;
  external?: string[];
  loaders?: LoaderMap;
  main_fields?: string[];
  target?: Target;
  serve?: boolean;
  env_files?: string[];
  extension_order?: string[];
  framework?: FrameworkConfig;
  router?: RouteConfig;
  no_summary?: boolean;
  disable_hmr?: boolean;
  port?: uint16;
  logLevel?: MessageLevel;
  source_map?: SourceMapMode;
}

export interface FileHandle {
  path: string;
  size: uint;
  fd: uint;
}

export interface Transform {
  handle?: FileHandle;
  path?: string;
  contents?: Uint8Array;
  loader?: Loader;
  options?: TransformOptions;
}

export interface Scan {
  path?: string;
  contents?: Uint8Array;
  loader?: Loader;
}

export interface ScanResult {
  exports: string[];
  imports: ScannedImport[];
  errors: Message[];
}

export interface ScannedImport {
  path: string;
  kind: ImportKind;
}

export interface OutputFile {
  data: Uint8Array;
  path: string;
}

export interface TransformResponse {
  status: TransformResponseStatus;
  files: OutputFile[];
  errors: Message[];
}

export interface Location {
  file: string;
  namespace: string;
  line: int32;
  column: int32;
  line_text: string;
  suggestion: string;
  offset: uint;
}

export interface MessageData {
  text?: string;
  location?: Location;
}

export interface MessageMeta {
  resolve?: string;
  build?: boolean;
}

export interface Message {
  level: MessageLevel;
  data: MessageData;
  notes: MessageData[];
  on: MessageMeta;
}

export interface Log {
  warnings: uint32;
  errors: uint32;
  msgs: Message[];
}

export interface NPMRegistry {
  url: string;
  username: string;
  password: string;
  token: string;
}

export interface NPMRegistryMap {
  scopes: string[];
  registries: NPMRegistry[];
}

export interface BunInstall {
  default_registry?: NPMRegistry;
  scoped?: NPMRegistryMap;
  lockfile_path?: string;
  save_lockfile_path?: string;
  cache_directory?: string;
  dry_run?: boolean;
  force?: boolean;
  save_dev?: boolean;
  save_optional?: boolean;
  save_peer?: boolean;
  save_lockfile?: boolean;
  production?: boolean;
  save_yarn_lockfile?: boolean;
  native_bin_links?: string[];
  disable_cache?: boolean;
  disable_manifest_cache?: boolean;
  global_dir?: string;
  global_bin_dir?: string;
  frozen_lockfile?: boolean;
  exact?: boolean;
  concurrent_scripts?: uint32;
}

export interface GetTestsRequest {
  path: string;
  contents: Uint8Array;
}

export interface TestResponseItem {
  byteOffset: int32;
  label: StringPointer;
  kind: TestKind;
}

export interface GetTestsResponse {
  tests: TestResponseItem[];
  contents: Uint8Array;
}

export declare function encodeStackFrame(message: StackFrame, bb: ByteBuffer): void;
export declare function decodeStackFrame(buffer: ByteBuffer): StackFrame;
export declare function encodeStackFramePosition(message: StackFramePosition, bb: ByteBuffer): void;
export declare function decodeStackFramePosition(buffer: ByteBuffer): StackFramePosition;
export declare function encodeSourceLine(message: SourceLine, bb: ByteBuffer): void;
export declare function decodeSourceLine(buffer: ByteBuffer): SourceLine;
export declare function encodeStackTrace(message: StackTrace, bb: ByteBuffer): void;
export declare function decodeStackTrace(buffer: ByteBuffer): StackTrace;
export declare function encodeJSException(message: JSException, bb: ByteBuffer): void;
export declare function decodeJSException(buffer: ByteBuffer): JSException;
export declare function encodeProblems(message: Problems, bb: ByteBuffer): void;
export declare function decodeProblems(buffer: ByteBuffer): Problems;
export declare function encodeRouter(message: Router, bb: ByteBuffer): void;
export declare function decodeRouter(buffer: ByteBuffer): Router;
export declare function encodeFallbackMessageContainer(message: FallbackMessageContainer, bb: ByteBuffer): void;
export declare function decodeFallbackMessageContainer(buffer: ByteBuffer): FallbackMessageContainer;
export declare function encodeJSX(message: JSX, bb: ByteBuffer): void;
export declare function decodeJSX(buffer: ByteBuffer): JSX;
export declare function encodeStringPointer(message: StringPointer, bb: ByteBuffer): void;
export declare function decodeStringPointer(buffer: ByteBuffer): StringPointer;
export declare function encodeStringMap(message: StringMap, bb: ByteBuffer): void;
export declare function decodeStringMap(buffer: ByteBuffer): StringMap;
export declare function encodeLoaderMap(message: LoaderMap, bb: ByteBuffer): void;
export declare function decodeLoaderMap(buffer: ByteBuffer): LoaderMap;
export declare function encodeEnvConfig(message: EnvConfig, bb: ByteBuffer): void;
export declare function decodeEnvConfig(buffer: ByteBuffer): EnvConfig;
export declare function encodeFrameworkConfig(message: FrameworkConfig, bb: ByteBuffer): void;
export declare function decodeFrameworkConfig(buffer: ByteBuffer): FrameworkConfig;
export declare function encodeFrameworkEntryPointMessage(message: FrameworkEntryPointMessage, bb: ByteBuffer): void;
export declare function decodeFrameworkEntryPointMessage(buffer: ByteBuffer): FrameworkEntryPointMessage;
export declare function encodeRouteConfig(message: RouteConfig, bb: ByteBuffer): void;
export declare function decodeRouteConfig(buffer: ByteBuffer): RouteConfig;
export declare function encodeTransformOptions(message: TransformOptions, bb: ByteBuffer): void;
export declare function decodeTransformOptions(buffer: ByteBuffer): TransformOptions;
export declare function encodeFileHandle(message: FileHandle, bb: ByteBuffer): void;
export declare function decodeFileHandle(buffer: ByteBuffer): FileHandle;
export declare function encodeTransform(message: Transform, bb: ByteBuffer): void;
export declare function decodeTransform(buffer: ByteBuffer): Transform;
export declare function encodeScan(message: Scan, bb: ByteBuffer): void;
export declare function decodeScan(buffer: ByteBuffer): Scan;
export declare function encodeScanResult(message: ScanResult, bb: ByteBuffer): void;
export declare function decodeScanResult(buffer: ByteBuffer): ScanResult;
export declare function encodeScannedImport(message: ScannedImport, bb: ByteBuffer): void;
export declare function decodeScannedImport(buffer: ByteBuffer): ScannedImport;
export declare function encodeOutputFile(message: OutputFile, bb: ByteBuffer): void;
export declare function decodeOutputFile(buffer: ByteBuffer): OutputFile;
export declare function encodeTransformResponse(message: TransformResponse, bb: ByteBuffer): void;
export declare function decodeTransformResponse(buffer: ByteBuffer): TransformResponse;
export declare function encodeLocation(message: Location, bb: ByteBuffer): void;
export declare function decodeLocation(buffer: ByteBuffer): Location;
export declare function encodeMessageData(message: MessageData, bb: ByteBuffer): void;
export declare function decodeMessageData(buffer: ByteBuffer): MessageData;
export declare function encodeMessageMeta(message: MessageMeta, bb: ByteBuffer): void;
export declare function decodeMessageMeta(buffer: ByteBuffer): MessageMeta;
export declare function encodeMessage(message: Message, bb: ByteBuffer): void;
export declare function decodeMessage(buffer: ByteBuffer): Message;
export declare function encodeLog(message: Log, bb: ByteBuffer): void;
export declare function decodeLog(buffer: ByteBuffer): Log;
export declare function encodeNPMRegistry(message: NPMRegistry, bb: ByteBuffer): void;
export declare function decodeNPMRegistry(buffer: ByteBuffer): NPMRegistry;
export declare function encodeNPMRegistryMap(message: NPMRegistryMap, bb: ByteBuffer): void;
export declare function decodeNPMRegistryMap(buffer: ByteBuffer): NPMRegistryMap;
export declare function encodeBunInstall(message: BunInstall, bb: ByteBuffer): void;
export declare function decodeBunInstall(buffer: ByteBuffer): BunInstall;
export declare function encodeGetTestsRequest(message: GetTestsRequest, bb: ByteBuffer): void;
export declare function decodeGetTestsRequest(buffer: ByteBuffer): GetTestsRequest;
export declare function encodeTestResponseItem(message: TestResponseItem, bb: ByteBuffer): void;
export declare function decodeTestResponseItem(buffer: ByteBuffer): TestResponseItem;
export declare function encodeGetTestsResponse(message: GetTestsResponse, bb: ByteBuffer): void;
export declare function decodeGetTestsResponse(buffer: ByteBuffer): GetTestsResponse;
