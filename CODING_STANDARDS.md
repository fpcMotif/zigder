# Coding standards

- **Sibling views.** When you fix a state or input bug in one `src/ui/*.zig` view, check all other views in `src/ui/` for the same pattern.
- **UI tests.** Drive regression tests in `src/tests/ui.zig` with `ui.Tester` clicks, double-clicks, and keys. Do not call `AppState` methods directly between frames.
- **Read-only render pass.** View functions in `src/ui/` take `*const AppState` and push `commands.Command` values into `commands.Queue`. `src/ui/view.zig` flushes the queue once after rendering.
- **Release checks.** Run `mise exec -- zig build check` so both Debug and ReleaseFast tests pass before delivering `zig-out/zigder.app`.
