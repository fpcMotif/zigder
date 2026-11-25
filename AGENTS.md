# zigder

- **State invariants.** Read `src/STATE_MACHINES.md` before editing `src/app/`, `src/index/`, or `src/ui/`.
- **Review rules.** Read `CODING_STANDARDS.md` before approving diffs or closing bugs under `src/`.
- **Verification.** Run `mise exec -- zig build check` after edits to `src/`, `tools/`, or `build.zig`. Run `mise exec -- zig build` before delivering `zig-out/zigder.app`.
- **UI tests.** Drive UI regression tests in `src/tests/ui.zig` through `ui.Tester` input events.
