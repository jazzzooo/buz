// The types in this file are not publicly defined, but do exist.
// Stuff like `Bun.fs()` and so on.

type BunFSWatchOptions = { encoding?: BufferEncoding; persistent?: boolean; recursive?: boolean; signal?: AbortSignal };
type BunWatchEventType = "rename" | "change" | "error" | "close";
type BunWatchListener<T> = (event: WatchEventType, filename: T | undefined) => void;

/**
 * If this is not tree-shaken away, the bundle will fail.
 */
declare function $bundleError(...message: any[]): never;

declare module "bun" {
  namespace SQL.__internal {
    type Define<T, K extends keyof T = never> = T extends any
      ? T & {
          [Key in K | "adapter"]: NonNullable<T[Key]>;
        } & {}
      : never;

    type Adapter = NonNullable<Bun.SQL.Options["adapter"]>;

    /**
     * Represents the result of the `parseOptions()` function in the sqlite path
     */
    type DefinedSQLiteOptions = Define<Bun.SQL.SQLiteOptions, "filename">;

    /**
     * Represents the result of the `parseOptions()` function in the postgres, mysql or mariadb path
     */
    type DefinedPostgresOrMySQLOptions = Define<Bun.SQL.PostgresOrMySQLOptions, "max" | "prepare" | "max"> & {
      sslMode: import("internal/sql/shared").SSLMode;
      query: string;
    };

    type DefinedOptions = (DefinedSQLiteOptions & { bigint?: undefined }) | DefinedPostgresOrMySQLOptions;
    type OptionsWithDefinedAdapter = Define<Bun.SQL.Options, "adapter">;
  }
}

interface BunFSWatcher {
  /**
   * Stop watching for changes on the given `BunFSWatcher`. Once stopped, the `BunFSWatcher` object is no longer usable.
   * @since v0.6.8
   */
  close(): void;

  /**
   * When called, requests that the Node.js event loop not exit so long as the <BunFSWatcher> is active. Calling watcher.ref() multiple times will have no effect.
   */
  ref(): void;

  /**
   * When called, the active <BunFSWatcher> object will not require the Node.js event loop to remain active. If there is no other activity keeping the event loop running, the process may exit before the <BunFSWatcher> object's callback is invoked. Calling watcher.unref() multiple times will have no effect.
   */
  unref(): void;
}
type BunFS = Omit<typeof import("node:fs") & typeof import("node:fs/promises"), "watch" | "cp" | "cpSync"> & {
  /**
   * Watch for changes on `filename`, where `filename` is either a file or a
   * directory.
   *
   * The second argument is optional. If `options` is provided as a string, it
   * specifies the `encoding`. Otherwise `options` should be passed as an object.
   *
   * The listener callback gets two arguments `(eventType, filename)`. `eventType`is either `'rename'`, `'change', 'error' or 'close'`, and `filename` is the name of the file
   * which triggered the event, the error when `eventType` is 'error' or undefined when eventType is 'close'.
   *
   * On most platforms, `'rename'` is emitted whenever a filename appears or
   * disappears in the directory.
   *
   *
   * If a `signal` is passed, aborting the corresponding AbortController will close
   * the returned `BunFSWatcher`.
   * @since v0.6.8
   * @param listener
   */
  watch(
    filename: string,
    options:
      | (WatchOptions & {
          encoding: "buffer";
        })
      | "buffer",
    listener?: BunWatchListener<Buffer>,
  ): BunFSWatcher;
  /**
   * Watch for changes on `filename`, where `filename` is either a file or a directory, returning an `BunFSWatcher`.
   * @param filename A path to a file or directory. If a URL is provided, it must use the `file:` protocol.
   * @param options Either the encoding for the filename provided to the listener, or an object optionally specifying encoding, persistent, and recursive options.
   * If `encoding` is not supplied, the default of `'utf8'` is used.
   * If `persistent` is not supplied, the default of `true` is used.
   * If `recursive` is not supplied, the default of `false` is used.
   */
  watch(
    filename: string,
    options?: WatchOptions | BufferEncoding | null,
    listener?: BunWatchListener<string>,
  ): BunFSWatcher;
  /**
   * Watch for changes on `filename`, where `filename` is either a file or a directory, returning an `BunFSWatcher`.
   * @param filename A path to a file or directory. If a URL is provided, it must use the `file:` protocol.
   * @param options Either the encoding for the filename provided to the listener, or an object optionally specifying encoding, persistent, and recursive options.
   * If `encoding` is not supplied, the default of `'utf8'` is used.
   * If `persistent` is not supplied, the default of `true` is used.
   * If `recursive` is not supplied, the default of `false` is used.
   */
  watch(
    filename: string,
    options: BunWatchListener | string,
    listener?: BunWatchListener<string | Buffer>,
  ): BunFSWatcher;
  /**
   * Watch for changes on `filename`, where `filename` is either a file or a directory, returning an `BunFSWatcher`.
   * @param filename A path to a file or directory. If a URL is provided, it must use the `file:` protocol.
   */
  watch(filename: string, listener?: BunWatchListener<string>): BunFSWatcher;

  // internal api is for fs.cp and fs.cpSync that is limited to a few options.
  // there is a js implementation for options like `filter` in `src/js/internal/fs/cp*`
  cpSync(
    source: string,
    dest: string,
    recursive?: boolean,
    errorOnExist?: boolean,
    force?: boolean,
    mode?: number,
  ): void;
  cp(source: string, dest: string, recursive?: boolean, errorOnExist?: boolean, force?: boolean, mode?: number): void;
};

declare module "bun" {
  namespace Serve {
    interface BaseServeOptions<WebSocketData> {
      /** Internal hook used by node:http to receive raw requests from Bun.serve. */
      onNodeHTTPRequest?: (...args: any[]) => void;
    }
  }

  namespace dns {
    // Internal natives consumed by node:dns; not part of the public API surface.
    function getServers(): string[];
    function lookupService(address: string, port: number): Promise<[hostname: string, service: string]>;
    function resolve(hostname: string, rrtype?: string): Promise<unknown[]>;
    function resolveAny(hostname: string): Promise<unknown[]>;
    function resolveSrv(hostname: string): Promise<unknown[]>;
    function resolveTxt(hostname: string): Promise<unknown[]>;
    function resolveSoa(hostname: string): Promise<unknown>;
    function resolveNaptr(hostname: string): Promise<unknown[]>;
    function resolveMx(hostname: string): Promise<unknown[]>;
    function resolveCaa(hostname: string): Promise<unknown[]>;
    function resolveNs(hostname: string): Promise<unknown[]>;
    function resolvePtr(hostname: string): Promise<unknown[]>;
    function resolveCname(hostname: string): Promise<unknown[]>;
    function reverse(ip: string): Promise<string[]>;
  }

  var TOML: {
    parse(contents: string): any;
    stringify(value: unknown, replacer?: undefined | null, space?: string | number): string | undefined;
  };
  function jest(path: string): typeof import("bun:test");
  var main: string;
  var tty: Array<{ hasColors: boolean }>;
  var FFI: any;
  /** This version of fetch is untamperable */
  var fetch: typeof globalThis.fetch;
}

/**
 * `JSC::JSModuleLoader`
 */
declare var Loader: {
  registry: Map<string, LoaderEntry>;

  parseModule(key: string, sourceCodeObject: JSCSourceCodeObject): Promise<LoaderModule> | LoaderModule;
  linkAndEvaluateModule(resolvedSpecifier: string, unknown: any);
  getModuleNamespaceObject(module: LoaderModule): any;
  requestedModules(module: LoaderModule): string[];
  dependencyKeysIfEvaluated(specifier: string): string[];
  resolve(specifier: string, referrer: string): string;
  ensureRegistered(key: string): LoaderEntry;
};

interface LoaderEntry {
  key: string;
  state: number;
  fetch: Promise<JSCSourceCodeObject>;
  instantiate: Promise<any>;
  satisfy: Promise<any>;
  dependencies: string[];
  module: LoaderModule;
  linkError?: any;
  linkSucceeded: boolean;
  evaluated: boolean;
  then?: any;
  isAsync: boolean;
  isSatisfied: boolean;
}

interface LoaderModule {
  dependenciesMap: Map<string, LoaderEntry>;
}

interface JSCommonJSModule {
  $require(id: string, mod: any, args_count: number, args: Array): any;
  $requireNativeModule(id: string): any;
  children: JSCommonJSModule[];
  exports: any;
  id: string;
  loaded: boolean;
  parent: undefined;
  path: string;
  paths: string[];
  require: typeof require;
  filename: string;
}

/**
 * Retrieves a handle to a function defined in a bindgen schema. For more information on how to define bindgen functions, see
 * [bindgen's documentation](https://bun.com/docs/project/bindgen).
 * @param filename - The basename of the `.schema.zig` file.
 * @param symbol - The name of the function to call.
 */
declare function $bindgenFn<T = (...args: any) => any>(filename: string, symbol: string): T;
declare function $bindgenClass<T = new (...args: any) => any>(filename: string, symbol: string): T;
// NOTE: $debug, $assert, and $isPromiseFulfilled omitted

declare namespace NodeJS {
  interface Process {
    /** Set when the process was started with `-e/--eval`; forwarded by node:child_process fork(). */
    _eval?: string;
  }
}

declare module "node:stream" {
  /** The internal state objects of readable/writable streams. Loosely typed: the
   * common flags are declared, everything else is reachable via the index signature. */
  interface InternalStreamState {
    ending: boolean;
    ended: boolean;
    finished: boolean;
    destroyed: boolean;
    constructed: boolean;
    closed: boolean;
    errored: Error | null;
    errorEmitted: boolean;
    [key: string]: any;
  }

  interface Writable {
    _writableState: InternalStreamState;
  }

  interface Readable {
    _readableState: InternalStreamState;
  }
}

declare module "node:net" {
  function _normalizeArgs(options: any[]): [Record<PropertyKey, any>, Function | null];

  /**
   * The implementation's view of a `Socket`: state internal to net/tls plus
   * writable versions of properties the public type exposes read-only.
   */
  interface SocketImpl extends Socket {
    bytesRead: number;
    connecting: boolean;
    timeout: number | undefined;
    connect(...args: any[]): this;
    _hadError: boolean;
    _pendingData: string | Uint8Array | null;
    _pendingEncoding: string;
    _host: string | null;
    _port?: number;
    _parent: unknown;
    _parentWrap: unknown;
    _peername: unknown;
    _sockname: unknown;
    _closeAfterHandlingError: boolean;
    addressType?: number;
    pauseOnConnect?: boolean;
    blockList?: BlockList;
    // TLS state, present when the socket is a TLSSocket
    isServer?: boolean;
    secureConnecting?: boolean;
    _securePending?: boolean;
    _secureEstablished?: boolean;
    _requestCert?: boolean;
    _rejectUnauthorized?: boolean;
    authorized?: boolean;
    authorizationError?: string | null;
    setSession?(session: unknown): void;
    getPeerCertificate?(detailed?: boolean): object;
  }

  interface Socket {
    _handle: Bun.Socket<any> | null;
    server: Server | null;
    _unrefTimer(): void;
    // TLS-populated fields readable on any socket flowing through the shared handlers
    alpnProtocol?: string | boolean | null;
    servername?: string;
  }

  interface Server {
    _handle: Bun.SocketListener<Socket> | null;
    _connections: number;
    pauseOnConnect: boolean;
    blockList?: BlockList;
  }
}
