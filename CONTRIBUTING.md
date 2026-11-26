# Contributing

## Requirements

macOS 26 or later, Apple silicon, and rustc 1.97 or later.

## Build

```sh
cargo build --release --examples
cargo build --release --examples --features private-api
cargo build --release -p founder
```

`private-api` is off by default. The plain build skips the examples that need it.

## Run Found'er

```sh
cargo run --release -p founder
```

A bare Cargo binary never becomes the key window. For anything that depends on focus, build the app and open it:

```sh
./founder/scripts/bundle.sh && open -n "dist/Found'er.app"
```

## The gate

Before you send a change, run:

```sh
./scripts/check.sh
```

It must end with `== VERDICT: PASS`. It builds both feature configs without warnings, checks formatting, runs unit tests and `probes/`, and builds the docs. It also runs `./scripts/surface.sh`, which fails if a change removes or alters a public item. The check opens a few small windows, so run it in an unlocked session.

`./scripts/perf.sh` runs the frame cadence step. It builds and launches the bundled Found'er and drives it with synthetic input, so the terminal needs:

* Screen Recording, for frame capture
* Accessibility, for the resize drag
* Automation of System Events, for window placement
* `swiftc`, from the Xcode command line tools

If a step exits 90, as `perf.sh` does on a locked screen, `check.sh` reports VOID and skips it. It does not fail the gate, but it did not run. `perf.sh` temporarily resets Found'er's saved window frame and restores yours on exit. `./scripts/keys.sh` and `./scripts/menubar.sh` list their own permission needs at the top of each script.

## Signing

`./founder/scripts/bundle.sh` signs with a Developer ID or Apple Development identity if the login keychain has one, or with `NG_CODESIGN_IDENTITY`. Otherwise it creates a self-signed "NativeGPUI Dev" identity in its own keychain, `~/Library/Keychains/nativegpui-dev.keychain-db`, and changes your keychain search list to include it. That keychain uses the public password `nativegpui` and allows any app to read the key. Treat it as a throwaway identity.

To remove it:

```sh
security delete-keychain ~/Library/Keychains/nativegpui-dev.keychain-db
```

`security delete-keychain` also drops it from the search list.

## Code

* Write a comment only where the code is incomprehensible without one.
* Refactors preserve behaviour.
* Keep the public API. `./scripts/surface.sh` fails on anything removed or changed.
* Use one gpui revision. Never use gpui from crates.io, and never use two revisions. `cargo tree -i gpui` must show one.

`crates/gpui-macos` holds zed's `gpui_macos` plus a small patch series. To move to a newer gpui, follow [crates/gpui-macos/UPSTREAM.md](crates/gpui-macos/UPSTREAM.md).

## Commits

* Use Conventional Commits with a lowercase imperative subject, for example `fix(founder): keep the selection after a rename`.
* The scope is the area you changed, such as `founder`, `finder-fs`, `sidebar`, `materials` or `gpui-macos`.
* Put one concern in each commit.
* Add no AI or tool attribution trailers.

## Releases

A release is `v<version>`, where `version` is in `founder/Cargo.toml`. To make one:

* Bump `version` in `founder/Cargo.toml`, with `Cargo.lock`.
* Add a `## <version>` section at the top of `founder/CHANGELOG.md`. Write short bullets for users. `./founder/scripts/notes.sh <version>` prints it.
* Push to `main`. CI builds the app and publishes `v<version>` with that section as its notes.

A push that doesn't change the version publishes nothing. CI fails before building if the section is missing or empty.

## License

By contributing, you license your contributions under the MIT license in [LICENSE](LICENSE). Changes under `crates/gpui-macos` are Apache-2.0, like the rest of that crate.
