# Plan 001: `zig build lines` and `zig build bench` configure from a clean cache

> **Executor instructions.** Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report. Do not improvise. When done, update the status row for this plan
> in `plans/README.md`.

> **Drift check.** Git does not track `build.zig` yet, so use a hash.
> Run `shasum -a 256 build.zig | cut -c1-12`. Expected: `c39bb0df26d3`.
> On a different value, compare the "Current state" excerpts with the live
> file. On a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: dx
- **Planned at**: commit `63a384c` (before git tracked `build.zig`, `zig/`, and `tools/`), 2026-11-24

## Why this matters

Every other plan in this folder verifies its work with `zig build test`,
`zig build lines`, and `zig build bench`. On 2026-11-24 the build script did
not compile from a clean cache with the pinned Zig 0.17.0. The default cache
then served a configuration with only the steps `test`, `app`, and `cli`, so
`zig build lines` and `zig build bench` failed with "no such step". This plan
makes the three steps work again from any cache.

## Current state

- `build.zig` is the build script at the repository root. It defines the steps
  `run`, `bench`, `test`, and `lines`.
- `mise.toml` pins `zig = "0.17.0"`. Always run Zig as `mise exec -- zig ...`.
- `build_state_tmp.zig` is a temporary file from another work session. Do not
  touch it.

The failing lines in `build.zig`:

```zig
// build.zig:55-57
    const opt_arg = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size");
    const app_optimize = opt_arg orelse .ReleaseFast;
    const test_optimize = opt_arg orelse .Debug;
```

```zig
// build.zig:99
    const bench_nanoui = if (app_optimize == .ReleaseFast)
```

The error from a clean cache:

```text
build.zig:56:34: error: no field named 'ReleaseFast' in enum 'lang.Optimize'
```

Cause: in Zig 0.17.0 the enum `std.builtin.OptimizeMode` has the fields
`debug`, `safe`, `fast`, `small`. Zig 0.17.0 deprecates the declaration names `Debug` and `ReleaseFast`.
A declaration name resolves only where the
expression has a known result type. `orelse` and `==` give no result type
here. The other uses in the file (`.optimize = .ReleaseFast` at lines 104 and
137, and the argument at line 109) have a result type and compile.

A scratch copy of the repository compiled the fix below on 2026-11-24.
It listed the steps `run`, `bench`, `test`, `lines`. `zig build lines` printed
`43 files, all within 600 lines`. `zig build test` exited 0.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| List steps | `mise exec -- zig build -l` | lists `run`, `bench`, `test`, `lines` |
| Line limit | `mise exec -- zig build lines` | `N files, all within 600 lines`, exit 0 |
| Tests | `mise exec -- zig build test` | exit 0 |

## Scope

**In scope:**
- `build.zig`

**Out of scope** (do NOT touch):
- `build_state_tmp.zig`. It belongs to another work session.
- `.zig-cache/`. Do not delete it. Another session can be building.
- Every file under `zig/` and `tools/`.

## Git workflow

- Do not commit, stage, or push. Git does not track `build.zig` yet, and the operator decides when the Zig port enters git.
- The repository commit style is conventional commits, for example
  `fix(founder): hold the preview width to what its divider allows`.

## Steps

### Step 1: Give the two optimize constants a type

In `build.zig`, replace lines 56 and 57 with:

```zig
    const app_optimize: std.builtin.OptimizeMode = opt_arg orelse .ReleaseFast;
    const test_optimize: std.builtin.OptimizeMode = opt_arg orelse .Debug;
```

### Step 2: Compare with the field name

In `build.zig`, replace line 99 with:

```zig
    const bench_nanoui = if (app_optimize == .fast)
```

**Verify**: `mise exec -- zig build -l` must list `bench`, `test`, and `lines`.

If the list still shows only `test`, `app`, and `cli`, the default cache is
stale. Run `mise exec -- zig build -l --cache-dir /tmp/zigder-plan-cache`.
If that lists `bench` and `lines`, the fix is correct. Report the stale cache
in your final message and add `--cache-dir /tmp/zigder-plan-cache` to every
`zig build` command in this plan.

### Step 3: Run the line check and the tests

**Verify**: `mise exec -- zig build lines` must print `N files, all within 600 lines` and exit 0.

**Verify**: `mise exec -- zig build test` must exit 0.

## Test plan

No new tests. The build steps are the check.

## Done criteria

- [ ] `mise exec -- zig build -l` lists `bench`, `test`, `lines`
- [ ] `mise exec -- zig build lines` exits 0
- [ ] `mise exec -- zig build test` exits 0
- [ ] Only `build.zig` changed, on exactly three lines
- [ ] `plans/README.md` status row updated

## STOP conditions

- `build.zig` does not match the excerpts above.
- `zig build test` fails with a compile error inside `zig/`. Another session is
  editing those files. Report the first error and stop.
- `zig build lines` reports a file over 600 lines. Report the file. Do not
  edit it.

## Maintenance notes

- Zig 0.18 removes the deprecated names `Debug` and `ReleaseFast`. The
  remaining uses at `build.zig:104`, `:109`, `:137` will then need `.fast`.
- `zig build bench` rewrites the index file at
  `~/Library/Caches/zigder/index.zidx` when it converts the index. This is
  existing behavior.
