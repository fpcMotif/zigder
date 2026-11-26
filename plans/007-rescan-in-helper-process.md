# Plan 007: The full index rescan runs in a helper process

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before the next step.
> If a "STOP conditions" item occurs, stop and report. Do not improvise. When
> done, update the row for this plan in `plans/README.md`.
>
> **Drift check (run first)**: this checkout is a JJ workspace with many
> uncommitted changes, so a git diff against the planned commit is not
> reliable. Compare each excerpt in "Current state" with the live file. A
> mismatch in text is a STOP condition. A line number that moved is not.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: none
- **Category**: perf
- **Planned at**: commit `33844b4` plus the uncommitted working tree, 2026-11-26

## Why this matters

A full rescan of `/` runs inside the app process. On 2026-11-26, with
2,400,747 entries, the app reached a peak footprint of 867 MB during the
rescan (`phys_footprint_peak` from `footprint <pid>`). After the rescan the
app stayed at 222 MB and fell to 149 MB. The live heap was about 13 MB. The
rest was freed memory that `malloc` kept dirty: 70.5 MB in
`Malloc Large (empty)` and 36.6 MB in `Malloc Small (empty)` (`vmmap
--summary`). `malloc_zone_pressure_relief` did not return it.

When the rescan runs in a child process, all of that memory belongs to the
child. The child exits, and the system takes the memory back. The app only
maps the finished index file.

This plan does not lower the memory that the rescan itself needs. The child
still reaches about 800 MB for about 50 seconds. See "Maintenance notes".

## Current state

Files:

- `src/index/engine.zig` (591 lines) — owns the worker thread. `buildAndAttach` does the scan and build in process.
- `src/index/walk.zig` — `scanCancel` walks the disk with N threads and keeps every listing in memory.
- `src/index/build.zig` — `buildFromListings` builds all index arrays in an arena, then writes the file.
- `src/index/tcc.zig` — `gatedPaths` returns the folders that the scan must skip.
- `src/main.zig` (161 lines) — app entry. Parses `--quit-after-ms=` and one path argument.
- `tools/lines.zig` — fails the build when a file under `src/` has more than 600 lines.

`src/index/engine.zig:488-501`, the code that moves:

```zig
        if (loaded_idx == null) {
            const root = cfg.scan_root orelse return;
            if (self.stopping.load(.acquire)) return;
            const skip_paths = tcc.gatedPaths(self.gpa, cfg.home) catch &.{};
            defer index_read.freePaths(self.gpa, skip_paths);
            const ev_now = fsevents.currentId();
            const sync_now = query_mod.nowSecs();
            var scan_res = walk.scanCancel(self.gpa, root, skip_paths, 4, &self.stopping) catch return;
            defer scan_res.deinit();
            if (self.stopping.load(.acquire)) return;
            index_build.buildFromListings(scan_res.listings.items, ev_now, sync_now, cfg.home, cfg.zidx_path) catch return;
            measure.releaseHeap();
            if (!self.stopping.load(.acquire)) loaded_idx = index_read.Index.load(cfg.zidx_path) catch null;
        }
```

`src/main.zig:28-37`, the argument loop:

```zig
    if (args.len > 1) {
        for (args[1..]) |arg| {
            if (std.mem.startsWith(u8, arg, "--quit-after-ms=")) {
                quit_after_ms = std.fmt.parseInt(u32, arg["--quit-after-ms=".len..], 10) catch null;
            } else if (!saw_path and arg.len > 0 and arg[0] != '-') {
                initial_path = arg;
                saw_path = true;
            }
        }
    }
```

`src/main.zig:73-77`, where the engine starts:

```zig
    var idle_rest: gpu_rest.IdleRest = .{};
    if (app.flags.snapshot == null) {
        idle_rest.install(win);
        try engine.startAsync(zidx_path, founder_path, "/", home, true);
    }
```

Conventions:

- The repo calls libc directly with `extern "c" fn` declarations at the top of the file. See `src/measure.zig:3-8` and `src/index/accel.zig` (`open`, `close`, `fsync`, `rename`). Match that style for `posix_spawn`, `waitpid`, `kill`, and `_NSGetExecutablePath`. Do not use `std.process.Child`.
- The Zig version is 0.17 development (`build.zig.zon`: `minimum_zig_version = "0.17.0"`). Standard library names differ from older releases. When unsure of an API, copy a call that already compiles in `src/`.
- Threads lock with `std.c.pthread_mutex_lock`. Atomic flags use `std.atomic.Value(bool)`.
- Tests live in `src/tests/*.zig`. `src/tests/engine.zig` is the pattern for engine tests. `src/tests/support.zig` has `TempDir.create`, `sh`, and `buildRootedIndex`.
- Read `src/STATE_MACHINES.md` section 1 before you edit `src/index/engine.zig`. Its invariant 5 says: "No thread calls `Stream.destroy` or `Thread.join` on a running worker while it holds `mutex`." This plan must not change which locks are held.
- Do not add or change comments, and do not edit Markdown files other than `plans/README.md`. A repository hook blocks those edits.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Line limit, Debug tests, ReleaseFast tests | `mise exec -- zig build check` | exit 0 |
| One test by name | `mise exec -- zig build test -Dtest-filter="rebuild:"` | exit 0 |
| Build the app bundle | `mise exec -- zig build` | exit 0, `zig-out/zigder.app` exists |
| Line limit only | `mise exec -- zig build lines` | exit 0 |

## Scope

**In scope** (the only files you may modify):

- `src/index/rebuild.zig` (create)
- `src/index/engine.zig`
- `src/main.zig`
- `src/tests/engine.zig`
- `plans/README.md` (status row only)

**Out of scope**:

- `src/index/walk.zig`, `src/index/build.zig`, `src/index/accel.zig` — the scan and the build stay as they are. Lowering their memory is a separate plan.
- `src/cli.zig` — the `zigder-cli index-build` command stays. The app bundle does not contain `zigder-cli`, so the helper must be the app binary itself.
- `build.zig` — no new executable.
- The `buildFromFounder` path at `src/index/engine.zig:476-486`. It stays in process.

## Git workflow

- This is a JJ workspace. Do not run `git commit`, `git checkout`, or `jj` commands that create or move changes. Leave your edits in the working copy.
- The operator lands the change. Recent subjects look like `perf(zig): remove SearchCache from inline search`.

## Steps

### Step 1: Create `src/index/rebuild.zig` with the in-process rebuild

Create the file with one public function that holds the code from
`engine.zig:491-499`:

```zig
pub fn runInProcess(
    gpa: std.mem.Allocator,
    root: []const u8,
    home: []const u8,
    zidx_path: []const u8,
    cancel: ?*const std.atomic.Value(bool),
) !void
```

It must: call `tcc.gatedPaths(gpa, home) catch &.{}` and free the result with
`index_read.freePaths`; read `fsevents.currentId()` and `query_mod.nowSecs()`
before the scan; call `walk.scanCancel(gpa, root, skip_paths, 4, cancel)`;
return `error.Canceled` when `cancel` is set after the scan; call
`index_build.buildFromListings(scan_res.listings.items, ev_now, sync_now,
home, zidx_path)`; call `measure.releaseHeap()`.

In `engine.zig`, replace lines 491-499 of the excerpt with:

```zig
            rebuild.runInProcess(self.gpa, root, cfg.home, cfg.zidx_path, &self.stopping) catch return;
```

Keep the two lines before it (`const root`, the `stopping` check) and the
`loaded_idx = index_read.Index.load` line after it. Add
`const rebuild = @import("rebuild.zig");` to the imports. Remove imports that
`engine.zig` no longer uses only if the compiler reports them.

**Verify**: `mise exec -- zig build check` → exit 0.

### Step 2: Add a spawn-and-wait function

In `src/index/rebuild.zig`, add:

```zig
pub fn spawnAndWait(argv: []const [*:0]const u8, cancel: ?*const std.atomic.Value(bool)) !void
```

Behaviour:

1. Build a null-terminated `[8]?[*:0]const u8` array from `argv`. Return `error.TooManyArgs` when `argv.len > 7`.
2. Call `posix_spawn(&pid, argv[0], null, null, &array, environ)`. Declare `extern "c" fn posix_spawn(...) c_int` and `extern "c" var environ: [*:null]?[*:0]u8`. Return `error.SpawnFailed` when the result is not 0.
3. Loop: call `waitpid(pid, &status, WNOHANG)` with `WNOHANG = 1`. When it returns `pid`, leave the loop. When `cancel` is set, call `kill(pid, 15)`, then `waitpid(pid, &status, 0)`, and return `error.Canceled`. Otherwise sleep 50 ms with `usleep(50_000)` (declare it `extern "c"`).
4. The child succeeded when `(status & 0x7f) == 0` and `((status >> 8) & 0xff) == 0`. Otherwise return `error.ChildFailed`.

**Verify**: Step 4's tests cover this. `mise exec -- zig build check` → exit 0.

### Step 3: Add the child entry point and use it

1. In `src/index/rebuild.zig`, add `pub fn childMain(gpa: std.mem.Allocator, args: []const []const u8) u8`. It expects exactly three arguments: root, output path, home. It calls `walk.noMaterialize()`, then `runInProcess(gpa, args[0], args[2], args[1], null)`. It returns 0 on success, 1 on error, 2 on a wrong argument count.
2. In `src/index/rebuild.zig`, add `pub fn run(gpa, helper_exe: ?[]const u8, root, home, zidx_path, cancel) !void`. When `helper_exe` is null, it calls `runInProcess`. Otherwise it makes zero-terminated copies of the four strings with `gpa.dupeSentinel(u8, s, 0)` (the name used at `src/index/walk.zig:494`), calls `spawnAndWait(&.{ exe, "--index-build", root, zidx_path, home }, cancel)`, and frees the copies. When `spawnAndWait` returns `error.SpawnFailed`, it falls back to `runInProcess`.
3. In `src/index/engine.zig`, add the field `helper_exe: ?[]const u8 = null,` to `Engine` (after `waker`). Change the call from Step 1 to `rebuild.run(self.gpa, self.helper_exe, root, cfg.home, cfg.zidx_path, &self.stopping) catch return;`.
4. In `src/main.zig`, directly after the `args` line (line 14), add: when `args.len >= 2` and `args[1]` equals `"--index-build"`, call `std.process.exit(rebuild.childMain(gpa, args[2..]))`. Import `index/rebuild.zig` as `rebuild`. This branch must run before `nanoui.App.create`.
5. In `src/main.zig`, before `engine.startAsync`, get the path of the running binary with `_NSGetExecutablePath(buf: [*]u8, size: *u32) c_int` into a `[4096]u8` buffer. When it returns 0, set `engine.helper_exe` to the zero-terminated slice. The buffer must be a `var` in `main` so it lives until `engine.stop()`.

**Verify**:

- `mise exec -- zig build check` → exit 0.
- `mise exec -- zig build` → exit 0.
- `zig-out/zigder.app/Contents/MacOS/zigder --index-build /usr/share /tmp/zigder-plan007.zidx "$HOME"; echo $?` → prints `0`, and no window opens.
- `zig-out/bin/zigder-cli index-status --index /tmp/zigder-plan007.zidx` → prints an `entries:` line with a number above 1000.
- `zig-out/zigder.app/Contents/MacOS/zigder --index-build; echo $?` → prints `2`.

### Step 4: Tests

Add to `src/tests/engine.zig`, using `support.TempDir` like the first test in
that file:

1. `test "rebuild: runInProcess writes an index that loads"` — make a temp folder with two files through `support.sh`, call `rebuild.runInProcess(gpa, root, root, idx_path, null)`, then `index_read.Index.load(idx_path)` and `deinit` it. Expect `idx.n >= 3`.
2. `test "rebuild: spawnAndWait reports the child's exit status"` — `spawnAndWait(&.{"/usr/bin/true"}, null)` succeeds. `spawnAndWait(&.{"/usr/bin/false"}, null)` returns `error.ChildFailed`. `spawnAndWait(&.{"/nonexistent/zigder-x"}, null)` returns `error.SpawnFailed`.
3. `test "rebuild: spawnAndWait stops the child when cancel is set"` — create `var cancel: std.atomic.Value(bool) = .init(true)`, call `spawnAndWait(&.{ "/bin/sleep", "30" }, &cancel)`. Expect `error.Canceled`. Measure the time with `measure.nanos()` and expect less than 2 seconds.

Before you write the code for test 3's cancel branch, run test 3 once with
the cancel branch missing and confirm that it fails or runs for 30 seconds.

**Verify**: `mise exec -- zig build test -Dtest-filter="rebuild:"` → exit 0, 3 tests pass.

## Done criteria

- [ ] `mise exec -- zig build check` exits 0
- [ ] `mise exec -- zig build` exits 0
- [ ] `rg -n "walk.scanCancel" src/index/engine.zig` prints nothing
- [ ] `rg -n "index-build" src/main.zig` prints one match
- [ ] The four commands in Step 3 "Verify" give the stated results
- [ ] Only the in-scope files changed (`jj status` or `git status --short`)
- [ ] `plans/README.md` status row updated

## STOP conditions

- An excerpt in "Current state" does not match the live file.
- `src/index/engine.zig` goes over 600 lines and you cannot get under the limit by the edits in this plan.
- `posix_spawn` of the app binary fails with a sandbox or code-signing error. Report the error number.
- The index from the child has far fewer entries than an in-process build of the same root (less than 90%). That means the child does not have the app's folder permissions. Report both counts.
- A verification fails twice after a fix attempt.

## Maintenance notes

- The child still needs about 800 MB for a scan of 2.4 million entries. A later plan can lower that: shrink `walk.RawEnt` (40 bytes per entry now), free each listing after `buildFromListings` copies it, and write index sections as they are built.
- The app-level effect is not in the done criteria, because nothing forces a full rescan on demand. To check it by hand: start the app from a terminal, wait until a second `zigder` process appears and exits, then run `footprint <app pid>` and read `phys_footprint_peak`. Expect less than 120 MB.
- `Engine.stop` now ends the child with SIGTERM. A half-written index is safe: `accel.writeZsidx` writes `<path>.tmp` and renames it at the end.
- A reviewer must check that `spawnAndWait` never runs while `Engine.mutex` is held. `buildAndAttach` runs on the worker thread without the lock today; that must stay true.
- Plan 008 adds a log line for the reason of each rescan. Run it after this plan, because both edit `src/index/engine.zig`.
