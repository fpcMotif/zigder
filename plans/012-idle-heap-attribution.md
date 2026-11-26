# Plan 012: A report names the owner of each megabyte of idle memory

> **Executor instructions**: This plan is an investigation. It changes no
> source file. Follow the steps, run every command, and write the report
> file. If a "STOP conditions" item occurs, stop and report. When done,
> update the row for this plan in `plans/README.md`.

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: LOW (read-only)
- **Depends on**: plans 007, 009, and 011 landed, so the report measures what is left
- **Category**: direction
- **Planned at**: commit `33844b4` plus the uncommitted working tree, 2026-11-26

## Why this matters

The owner wants the app under 20 MB when idle. A fresh start measured 38 to
54 MB on 2026-11-26, and `mise exec -- zig build bench` printed
`idle_mb=41.31`. An allocation call tree from the running app showed
48.8 MB live, in these groups:

| Group | Size | Owner |
|---|---|---|
| Metal drawables (`CAMetalLayerPrivateNextDrawableLocked` → `IOSurfaceCreate`) | 12.5 MB | QuartzCore, sized by the window |
| CoreAnimation commit and AppKit layer drawing (`CA::Transaction::commit`) | 8.7 MB | AppKit controls inside the window |
| `ui.context.Context.begin` | 4.0 MB | nanoui frame arena |
| `window.Window.create` (other than the first frame) | 4.1 MB | nanoui window setup |
| `ui.layout.measure` (21,125 allocations) | 4.0 MB | nanoui text and symbol caches |
| `ui.paint.paint` and `ui.metal_images.makeImagesTexture` | 2.2 MB | nanoui paint buffers and image atlas |
| System framework data (`__DATA`, `__DATA_DIRTY`, `__AUTH`, page tables, stacks) | about 9 MB | every AppKit process |

Most of this belongs to the nanoui dependency and to AppKit, not to code in
`src/`. A 20 MB target is not reachable without changes there. This plan
produces the facts for that decision: which nanoui allocations have a knob,
and what each knob saves.

## Current state

- `build.zig.zon` pins nanoui: `git+https://github.com/justrach/nanoui#cfe60007e2ace7dc3f2a114d00a938d1cbdd1d26`, hash `nanoui-0.14.9-we0KMW4DYgADBHlTy09LSLJPPzx4IvUTqtlyZhWZSsFs`.
- The unpacked source is in the Zig package cache. `mise exec -- zig env` prints `global_cache_dir`; the package is at `<global_cache_dir>/p/nanoui-0.14.9-we0KMW4DYgADBHlTy09LSLJPPzx4IvUTqtlyZhWZSsFs/`.
- `src/ui/gpu_rest.zig` already releases GPU buffers, layer textures, and the command queue after 250 ms without a frame (`IdleRest.onTimer`, lines 105-119), and shrinks the image atlas to 512 pixels (`tuneImages`, lines 7-30). Do not report those as new ideas.
- `src/main.zig:60-68` creates the window at 1220 × 780 points.

## Commands you will need

| Purpose | Command |
|---|---|
| Build the app | `mise exec -- zig build` |
| Start with allocation stacks | `MallocStackLogging=1 zig-out/zigder.app/Contents/MacOS/zigder --quit-after-ms=120000 2>/dev/null &` |
| Footprint by category | `footprint <pid>` |
| Live allocations as a call tree | `malloc_history <pid> -callTree > /tmp/zigder-tree.txt` |
| Heap zones and fragmentation | `vmmap --summary <pid>` |

`MallocStackLogging` adds about 16 MB of its own ("Performance Tool Data" in
`footprint`). Subtract it.

## Scope

**In scope**: create `plans/012-report.md`. Update the status row in `plans/README.md`.

**Out of scope**: every file under `src/`, `build.zig`, and the nanoui package cache. Do not edit the cached nanoui source.

## Steps

### Step 1: Capture two states

1. Build. Start the app with the command above. Note the pid with `echo $!`.
2. Wait 20 seconds without touching the window. This is the **rested** state. Run `footprint <pid>`, `vmmap --summary <pid>`, and `malloc_history <pid> -callTree > /tmp/zigder-rested.txt`.
3. Click in the window and scroll the file list for a few seconds. Within 1 second of the last input, run the same three commands with the output file `/tmp/zigder-active.txt`. This is the **active** state.

**Verify**: both tree files exist and are larger than 1 MB (`ls -l /tmp/zigder-*.txt`).

### Step 2: Build the owner table

For each state, list every call-tree node of 500 KB or more whose frame is
in `zigder` (the line contains `(in zigder)`) and whose parent frame is
smaller or is a system frame. This gives the top-most app-owned nodes. Use:

```bash
rg -n "\([0-9.]+M\)|\([5-9][0-9][0-9](\.[0-9]+)?K\)" /tmp/zigder-rested.txt | rg "in zigder"
```

For each node record: function name, size in the rested state, size in the
active state.

**Verify**: the table has at least the rows `ui.context.Context.begin`,
`window.Window.create`, and `ui.layout.measure`. If one is missing, the call
tree is not from this binary; STOP.

### Step 3: Find the knob for each nanoui row

For each nanoui function in the table, open its source in the package cache
and find the allocation. Record: file and line, what sets the size (a
constant, a window size, a count that grows), and whether `src/` can change
it through a public field or option without editing nanoui. `src/ui/gpu_rest.zig:7-30`
shows the kind of public field that counts (`im.limits.decoded_bytes`,
`im.side`).

**Verify**: every nanoui row has a file and line and one of three labels:
`public knob`, `needs nanoui change`, `fixed cost`.

### Step 4: Separate the system share

From the rested `footprint` output, sum the rows that no app code controls:
`__DATA`, `__DATA_DIRTY`, `__AUTH`, `page table`, `Stack`, `Malloc Metadata`,
`unused dyld shared cache area`, `__TPRO_CONST`. From `vmmap --summary`, read
the `DefaultMallocZone` row and record the allocated bytes and the
fragmentation percentage.

**Verify**: the report states one number for "system floor" and one for
"malloc fragmentation".

### Step 5: Write `plans/012-report.md`

Sections, in this order:

1. **Result** — rested footprint, active footprint, system floor.
2. **Owner table** — from Steps 2 and 3.
3. **What a public knob can save** — the sum of the `public knob` rows.
4. **What needs a nanoui change** — the list, with the size of each.
5. **Reachable idle target** — rested footprint minus the two sums above. State it as a number. State whether 20 MB is reachable, and what must change for it.

**Verify**: `rg -c "^## " plans/012-report.md` prints `5`.

## Done criteria

- [ ] `plans/012-report.md` exists with the five sections
- [ ] Every size in the report comes from a command output of this run, with the command named
- [ ] `git status --short src build.zig` shows no change made by this plan
- [ ] `plans/README.md` status row updated

## STOP conditions

- The package cache folder for the pinned nanoui hash does not exist. Report the output of `mise exec -- zig env`.
- `malloc_history` reports that the process has no stack logs.
- The rested footprint is above 120 MB. A rescan or event replay is then running; wait until `ps -o pcpu= -p <pid>` is under 2 and capture again. If it stays high for 5 minutes, STOP.

## Maintenance notes

- This report is the input for a decision by the owner: accept about 30 MB idle, or fund changes in nanoui. Do not start those changes from this plan.
- The 12.5 MB of drawables scale with the window's pixel size. A report line must give the window size used.
- The numbers in "Why this matters" predate plans 007, 009, and 011. Do not copy them into the report.
