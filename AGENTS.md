# zigder

- **State invariants**: Read `zig/STATE_MACHINES.md` before editing `zig/app*.zig`, `zig/engine.zig`, `zig/live*.zig`, `zig/fsevents.zig`, or `zig/view_*.zig`.
- **Review rules**: Read `CODING_STANDARDS.md` before approving diffs or closing bugs under `zig/`.
- **Verification**: Run `mise exec -- zig build check` after edits to `zig/`, `tools/`, or `build.zig`, and run `mise exec -- zig build` before delivering `zig-out/zigder.app`.
- **UI tests**: Drive UI regression tests in `zig/tests_ui.zig` through `ui.Tester` input events.
