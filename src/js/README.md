# JS Modules

Run `./zig build` from the repository root after changing these sources.

- `./node` contains all `node:*` modules
- `./bun` contains all `bun:*` modules
- `./thirdparty` contains npm modules we replace like `ws`
- `./internal` contains modules that aren't assigned to the module resolver

Each `.ts`/`.js` file above is assigned a numeric id at compile time and inlined into an array of lazily initialized modules. Internal modules referencing each other is extremely optimized, skipping the module resolver entirely.

## Builtins Syntax

Within these files, the `$` prefix on variables can be used to access private property names as well as JSC intrinsics.

```ts
// Many globals have private versions which are impossible for the user to
// tamper with. Though, these global variables are auto-prefixed by the bundler.
const hello = $Array.from(...);

// Similar situation with prototype values. These aren't autoprefixed since it depends on type.
something.$then(...);
map.$set(...);

// Internal variables we define
$requireMap.$has("elysia");

// JSC engine intrinsics. These usually translate directly to bytecode instructions.
const arr = $newArrayWithSize(5);
// A side effect of this is that using an intrinsic incorrectly like
// this will fail to parse and cause a segfault.
console.log($getInternalField)
```

V8 has a [similar feature](https://v8.dev/blog/embedded-builtins) to this syntax (they use `%` instead)

On top of this, we have some special functions that are handled by the builtin preprocessor:

- `require` works, but it must be passed a **string literal** that resolves to a module within `src/js`. This call gets replaced with `$getInternalField($internalModuleRegistry, <number>)`, which directly loads the module by its generated numerical ID, skipping the resolver for inter-internal modules.

- `$debug()` is exactly like console.log, but is stripped in release builds. It is disabled by default, requiring you to pass one of: `BUN_DEBUG_MODULE_NAME=1`, `BUN_DEBUG_JS=1`, or `BUN_DEBUG_ALL=1`. You can also do `if($debug) {}` to check if debug env var is set.

- `$assert()` in debug builds will assert the condition, but it is stripped in release builds. If an assertion fails, the program continues to run, but an error is logged in the console containing the original source condition and any extra messages specified.

- `IS_BUN_DEVELOPMENT` is inlined to be `true` in all development builds.

- `process.platform` and `process.arch` is properly inlined and DCE'd. Do use this to run different code on different platforms.

## Builtin Modules

Files in `node`, `bun`, `thirdparty`, and `internal` are all bundled as "modules". These go through the preprocessor to construct a JS function, where `export default`/`export function`/etc are converted into a `return` statement. Due to this, non-type `import` statements are not supported.

By using `export default`, this controls the result of using `require` to import the module. When ESM imports this module (userland), all properties on this object are available as named exports. Named exports are preprocessed into properties on this default object.

```ts
const fs = require("fs"); // load another builtin module

export default {
  hello: 2,
  world: 3,
};
```

Keep in mind that **these are not ES modules**. `export default` is only syntax sugar to assign to the variable `$exports`, which is actually how the module exports its contents.

Binding schemas declare native module surfaces. The build emits their module registry and resolves builtin references at build time.

## Builtin functions

`./builtins` contains isolated functions, bundled separately. They cannot capture module variables or import runtime values. Builtins reach native code through schema declarations such as `$bindgenFn`, and public functions and methods select a `.builtin` backend in their schemas.

Files marked `// @internal` have generated per-realm function storage and GC visitation. Engine integrations use that storage instead of creating and caching additional copies of the same builtin.

## Building

Run `./zig build` from the repository root. It bundles the JavaScript and emits the binding artifacts under `build/zig/`. Debug builds load bundled JavaScript from that build directory; release builds embed it. Generated files are build outputs and are not committed.

## Notes on how the build process works

_This isn't really required knowledge to use it, but a rough overview of how ./\_codegen/\* works_

The build process is built on top of Bun's bundler. The first step is scanning all modules and assigning each a numerical ID. The order is determined by an A-Z sort.

The `$` for private names is actually a lie, and in JSC it actually uses `@`; though that is a syntax error in regular JS/TS, so we opted for better IDE support. So first we have to pre-process the files to spot all instances of `$` at the start of an identifier and we convert it to `__intrinsic__`. We also scan for `require(string)` and replace it with `$requireId(n)` after resolving it to the integer id, which is defined in `./functions/Module.ts`. `export default` is transformed into `return ...;`, however this transform is a little more complicated that a string replace because it supports that not being the final statement, and access to the underlying variable `$exports`, etc.

The preprocessor is smart enough to not replace `$` in strings, comments, regex, etc. However, it is not a real JS parser and instead a recursive regex-based nightmare, so may hit some edge cases. Yell at Chloe if it breaks.

The module is then printed like:

```ts
// @ts-nocheck
$$capture_start$$(function () {
  const path = __intrinsic__requireId(23);
  // user code is pasted here
  return {
    cool: path,
  };
}).$$capture_end$$;
```

This capture thing is used to extract the function declaration afterwards, this is more useful in the functions case where functions can have arguments, or be async functions.

After bundling, the inner part is extracted, and then `__intrinsic__` is replaced to `@`.

These can then be inlined into C++ headers and loaded with `createBuiltin`. This is done in `InternalModuleRegistry.cpp`.
