# Prebuilt dependency archives

## liblolhtml.a (x86_64-linux)

Built from the lolhtml source pinned in build.zig.zon, in its `c-api/`
directory:

    CARGO_ENCODED_RUSTFLAGS=$'-Zunstable-options\x1f-Cpanic=immediate-abort\x1f-Cdebuginfo=0\x1f-Cforce-unwind-tables=no\x1f-Copt-level=s' \
    cargo build --locked --release --target x86_64-unknown-linux-gnu -Zbuild-std=std,panic_abort

    cargo 1.94.0-nightly (2c283a9a5 2025-12-04)
    rustc 1.94.0-nightly (c61a3a44d 2025-12-09)

C ABI, so the one release-profile archive is linked into both debug and
release builds.
