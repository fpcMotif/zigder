# Coding Standards

- **Sibling sweep**: When a fix addresses a lifetime, state-transition, or interaction bug in one `zig/view_*.zig` file, audit all sibling `zig/view_*.zig` files (`view_list`, `view_icon`, `view_gallery`, `view_column`, `view_chrome`, `view_overlays`, `view_inspector`) for the same pattern before approving.
- **Boundary testing**: Trigger UI regression tests in `zig/tests_ui.zig` through `ui.Tester` clicks, double-clicks, and keys rather than calling `AppState` methods directly between frames.
- **Deferred render-loop mutations**: Record user-triggered listing, tab, or path mutations inside render loops (`while` and `for` loops) and apply them after the loop finishes. `mise exec -- zig build view-loops` checks `while (...next())` loops automatically; inspect `for` loops and slice borrows during review.
- **Release parity**: Confirm both Debug and ReleaseFast test suites pass via `mise exec -- zig build check` before delivering `zig-out/zigder.app`.
