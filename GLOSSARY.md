# zigder

A native macOS file browser and file search app.

## Language

**Command**:
A value (`commands.Command`) that a menu item, shortcut, or view pushes into `commands.Queue` to change `AppState`.
_Avoid_: Action, handler, callback

**Engine**:
The background worker (`Engine`) that builds or loads the index, applies FSEvents batches, runs searches, and wakes the UI.
_Avoid_: Index manager, service

**Live overlay**:
The in-memory delta (`Live`) over the memory-mapped base index. It records deleted entries, folder mtime changes, and added or replaced paths.
_Avoid_: Cache, patch layer

**Host**:
The callback struct (`app.Host`) for window titles, redraws, window close, Finder open, and native menu edit actions.
_Avoid_: Window delegate, UI callback
