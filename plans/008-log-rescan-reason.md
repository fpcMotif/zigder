# Plan 008: Each full rescan logs its reason

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before the next step.
> If a "STOP conditions" item occurs, stop and report. Do not improvise. When
> done, update the row for this plan in `plans/README.md`.
>
> **Drift check (run first)**: this checkout is a JJ workspace with
> uncommitted changes. Compare each excerpt in "Current state" with the live
> file. A mismatch in text is a STOP condition. A moved line number is not.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: plans/007-rescan-in-helper-process.md (both edit `src/index/engine.zig`, which has a 600-line limit)
- **Category**: perf
- **Planned at**: commit `33844b4` plus the uncommitted working tree, 2026-11-26

## Why this matters

A full rescan of `/` costs about 50 seconds at 275% CPU and about 800 MB.
On 2026-11-26 the app started with an index that was 1 hour 46 minutes old.
It replayed file events for about 40 seconds at 52% CPU and then did a full
rescan. A start 2 minutes after that rescan did no rescan. The code has four
places that request a rescan, and nothing records which one fired. Without
that fact, a fix is a guess.

This plan adds one log line per rescan request and a procedure to capture it.
It changes no behaviour. The fix is a later plan that uses the captured
reason.

## Current state

- `src/index/engine.zig` — the engine. Four sites request a rescan.
- `src/index/accel.zig` — has `pub fn writeFd(fd: c_int, bytes: []const u8) void`, used by `src/cli.zig:20` to print. Use it for the log line with `fd = 2`.
- `src/STATE_MACHINES.md` lists this as open hazard H3: "Every dropped-event flag costs a full scan. The Rust code first replays the gap up to 3 times."

`src/index/engine.zig:291-296` (inside `syncTargets`):

```zig
                for (fetched.items) |*ft| {
                    const outcome = live_sync.applyFetched(lv, ft, skip_paths, &pending) catch {
                        res.rescan = true;
                        continue;
                    };
                    if (outcome.need_rebuild) res.rescan = true;
```

`src/index/engine.zig:391-403` (inside `processEventsBatch`):

```zig
        for (batch) |ev| {
            if (ev.id > max_id) max_id = ev.id;
            if ((ev.flags & fsevents.HISTORY_DONE) != 0) continue;
            if ((ev.flags & (fsevents.USER_DROPPED | fsevents.KERNEL_DROPPED)) != 0) {
                rescan = true;
                continue;
            }
            const cp = live_sync.canonicalEventPath(ev.path) orelse continue;
            const rec = (ev.flags & fsevents.MUST_SCAN_SUBDIRS) != 0;
            if (rec and std.mem.eql(u8, cp, "/")) {
                rescan = true;
                continue;
            }
```

Flag values, `src/index/fsevents.zig:18-21`: `MUST_SCAN_SUBDIRS = 0x1`,
`USER_DROPPED = 0x2`, `KERNEL_DROPPED = 0x4`, `HISTORY_DONE = 0x10`.

Conventions:

- `tools/lines.zig` fails the build when a file under `src/` has more than 600 lines. `engine.zig` has 591 lines before plan 007 and fewer after it.
- No new comments. No Markdown edits except `plans/README.md`. A repository hook blocks both.
- Read `src/STATE_MACHINES.md` section 2 before you edit `engine.zig`. Its invariant: "Stale always leads to a rescan request." This plan must keep every `rescan = true` assignment.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| All checks | `mise exec -- zig build check` | exit 0 |
| One test | `mise exec -- zig build test -Dtest-filter="rescan reason"` | exit 0 |
| Build the app | `mise exec -- zig build` | exit 0 |

## Scope

**In scope**: `src/index/rescan_reason.zig` (create), `src/index/engine.zig`, `src/tests/engine.zig`, `plans/README.md` (status row).

**Out of scope**: any change to when a rescan happens. `src/index/live_sync.zig`. `src/index/fsevents.zig`.

## Git workflow

JJ workspace. Do not commit or move changes. The operator lands the work.
Subject style: `chore(zig): log the reason for each index rescan`.

## Steps

### Step 1: Add the reason module

Create `src/index/rescan_reason.zig`:

- `pub const Reason = enum(u8) { user_dropped, kernel_dropped, root_must_scan, apply_failed, need_rebuild };`
- `pub var counts: [5]std.atomic.Value(u32) = @splat(.init(0));`
- `pub fn note(r: Reason, flags: u32) void` — adds 1 to `counts[@intFromEnum(r)]`, then formats `zigder: rescan reason=<tag name> flags=0x<hex>\n` into a 96-byte stack buffer with `std.fmt.bufPrint` and writes it with `accel.writeFd(2, ...)`.
- `pub fn count(r: Reason) u32`.

**Verify**: `mise exec -- zig build check` → exit 0.

### Step 2: Call it at the four sites

In `src/index/engine.zig`, import the module as `rescan_reason`. Put each
call on the same line as the existing assignment, so the file gains only the
import line:

- Dropped flags (line 395): `rescan = true;` becomes a call to `rescan_reason.note(if ((ev.flags & fsevents.KERNEL_DROPPED) != 0) .kernel_dropped else .user_dropped, ev.flags);` followed by `rescan = true;`.
- Root `MUST_SCAN_SUBDIRS` (line 401): add `rescan_reason.note(.root_must_scan, ev.flags);`.
- `applyFetched` error (line 293): add `rescan_reason.note(.apply_failed, 0);`.
- `outcome.need_rebuild` (line 296): change to `if (outcome.need_rebuild) { rescan_reason.note(.need_rebuild, 0); res.rescan = true; }`.

**Verify**: `mise exec -- zig build check` → exit 0 (includes the line limit).

### Step 3: Test

Add to `src/tests/engine.zig`, modelled on the first test in that file
(`TempDir`, `buildRootedIndex`, `initHeadlessWithIndex`):

`test "engine: rescan reason counts a dropped flag and a root rescan event"` —
read `rescan_reason.count(.kernel_dropped)` and `count(.root_must_scan)`.
Call `eng.processEventsBatch(&.{.{ .path = "/", .flags = fsevents.KERNEL_DROPPED, .id = 20 }}, &.{})`
and then the same with `.flags = fsevents.MUST_SCAN_SUBDIRS`. Expect each
count to rise by exactly 1. The headless engine has no scan root, so
`requestRescan` does nothing.

Run the test once before Step 2 is in place and confirm that it fails.

**Verify**: `mise exec -- zig build test -Dtest-filter="rescan reason"` → exit 0.

### Step 4: Capture the reason from a real start

1. `mise exec -- zig build` → exit 0.
2. Quit every running `zigder`. Leave the index file untouched for at least 2 hours of normal computer use.
3. Run `zig-out/zigder.app/Contents/MacOS/zigder --quit-after-ms=180000 2> /tmp/zigder-rescan.log`.
4. Run `rg "rescan reason" /tmp/zigder-rescan.log`.

Write the matched lines, or "no rescan in 180 s", into your report. If you
can not wait 2 hours, report that Step 4 is not done and leave the plan
status as `IN PROGRESS`.

## Done criteria

- [ ] `mise exec -- zig build check` exits 0
- [ ] `rg -c "rescan_reason.note" src/index/engine.zig` prints `4`
- [ ] The new test passes
- [ ] The report contains the Step 4 lines
- [ ] Only in-scope files changed
- [ ] `plans/README.md` status row updated

## STOP conditions

- An excerpt does not match the live file.
- `engine.zig` exceeds 600 lines. Plan 007 must land first.
- Any edit would remove or move a `rescan = true` assignment.

## Maintenance notes

What the reason decides, for the follow-up plan:

| Captured reason | Meaning | Follow-up |
|---|---|---|
| `user_dropped` without `kernel_dropped` | The event service still has the lost events. | Restart the stream from `Live.event_id` up to 3 times before a rescan. The Rust reference does this in `apply_loop`, `ref/rust/founder/crates/fsearch/src/engine.rs:720-800`. The batch that carries the flag must not advance `Live.event_id`. |
| `kernel_dropped` or `root_must_scan` | History is gone. | Relist only folders whose modification time is newer than `Live.synced_at` (`relist_changed` in the same Rust file), not a full scan. |
| `need_rebuild` | A recursive event named `/`. | Same as the row above. |
| no rescan | The 2026-11-26 rescan had another cause. | Capture again with a longer gap. |

The second cost at start is the replay itself. The overlay is never written
back to the index file (open hazard H4), so each start replays every event
since the last full build. Writing the overlay back is a larger design and is
not planned yet.
