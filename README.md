# Buz

Buz is an early-stage experimental fork of pre-Rust Bun. The goal of the fork is to be a drop-in replacement for Bun.

## Features

- Tracks Zig's master branch.
- Supports sub-second incremental compilation.
- Uses `build.zig` as the build-system entry point.
- Builds most dependencies from source, including JavaScriptCore and ICU, enabling fast incremental builds of vendored WebKit code.
- Over 11,000 lines of dead code removed from upstream Bun.
- Includes Bun's upstream test suite.

## Work in progress

- Currently only native `x86_64-linux-gnu` builds and tests are in scope.
- The full upstream test suite does not pass yet.
- The codebase is still being refactored and deslopified. It is not ready for human review. It will take at least a few weeks of LLM-assisted cleanup before it's worthy of human contributor attention.
- This codebase contains numerous known, unpatched vulnerabilities and uses an outdated version of JavaScriptCore that lacks the latest security fixes. Do not use in production.

## Contributing

**All contributions at this stage must be LLM-assisted.** This policy will be lifted when the test suite is passing and the codebase is sufficiently cleaned up.

All accepted contributions must conform to the following:

- Make all tests pass in at least one currently failing test file.
- Fix the problem at the right scope. If a whole subsystem needs a rewrite, do not send in a set of small patches on a bad foundation.
- Your changes should make the codebase cleaner and more idiomatic. Always reduce technical debt.
- The PR must be merge-ready as far as you can tell. If either Sol Max or Fable Max finds anything actionable in your PR, it will not be accepted. This includes correctness, performance, simplicity, and maintainability. Human time will not be wasted on flaws that non-humans can spot.
- By submitting a contribution, you agree to license your contribution under the Unlicense.

## Building

### Bootstrap Zig

You will need CMake >=3.15 and LLVM + Clang + LLD at Zig's currently supported version, 22.x as of writing.

```sh
git submodule update --init --recursive
```

```sh
cd zig-upstream
mkdir build
cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make install
cd ../..
```

### Build commands

Incremental debug build:

```sh
./zig build --watch -fincremental
```

Release build (for running the full test suite):

```sh
./zig build --release=fast
```

## Running tests

Install the Node.js version pinned in `.nvmrc`:

```sh
nvm install
```

Also install:

- Docker Compose V2.
- FUSE 2, its Python bindings, and fusermount.
- GNOME Keyring, D-Bus, and libsecret.

```sh
BUN_AGENT_RULE_DISABLED=1 node scripts/runner.node.mjs --exec-path ./zig-out/bin/bun --retries 0 >test-sweep.log 2>&1
```

## License

Original Buz contributions are released under [the Unlicense](UNLICENSE). Inherited and third-party code retains its existing licensing; see [third-party notices](THIRD_PARTY_NOTICES.md) for details.

## Disclaimer

Buz is not endorsed by or affiliated with Oven or its parent company, Anthropic. Any Bun branding, such as logos or URLs, will be removed on a best-effort basis.
