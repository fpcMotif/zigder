# Plan 009: Search scratch memory is released when a search ends

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before the next step.
> If a "STOP conditions" item occurs, stop and report. Do not improvise. When
> done, update the row for this plan in `plans/README.md`.
>
> **Drift check (run first)**: this checkout is a JJ workspace with
> uncommitted changes. Compare each excerpt in "Current state" with the live
> file. A mismatch in text is a STOP condition. A moved line number is not.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: plans/007-rescan-in-helper-process.md (line budget of `src/index/engine.zig`)
- **Category**: perf
- **Planned at**: commit `33844b4` plus the uncommitted working tree, 2026-11-26

## Why this matters

`mise exec -- zig build bench` on 2026-11-26 (2,400,747 entries) printed
`idle_mb=41.31` before the search rows and `after_search_mb=67.81` after
them. The app keeps about 26 MB after searches end. The target for the app's
peak is 80 MB, so 26 MB of idle scratch is a third of the budget.

The cause is not yet attributed. The first step measures the search scratch
buffers. The plan continues only when they explain at least 5 MB.

## Current state

- `src/search/search.zig` — `Searcher` owns a thread pool and a `Scratch`.
- `src/search/memo.zig` — `Scratch` holds three arrays sized by the index.
- `src/search/nfa.zig` — `Pool.runScan` keeps per-shard hit lists.
- `src/index/engine.zig` — owns the one `Searcher`, guarded by `Engine.mutex`.
- `src/app/app.zig` — `clearInlineSearch` runs when the search field empties.
- `src/bench.zig` — prints `after_search_mb`.

`src/search/search.zig:58-73`:

```zig
pub const Searcher = struct {
    gpa: std.mem.Allocator,
    pool: ?*search_nfa.Pool = null,
    scratch: search_memo.Scratch = .{},

    pub fn init(gpa: std.mem.Allocator) Searcher {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Searcher) void {
        if (self.pool) |p| {
            p.destroy(self.gpa);
            self.pool = null;
        }
        self.scratch.deinit(self.gpa);
    }
```

`src/search/memo.zig:15-27`:

```zig
pub const Scratch = struct {
    name_lookup: []i32 = &.{},
    bits: []u8 = &.{},
    best: []i16 = &.{},
    dir_hits: std.ArrayList(u32) = .empty,

    pub fn deinit(s: *Scratch, gpa: std.mem.Allocator) void {
        if (s.name_lookup.len > 0) gpa.free(s.name_lookup);
        if (s.bits.len > 0) gpa.free(s.bits);
        if (s.best.len > 0) gpa.free(s.best);
        s.dir_hits.deinit(gpa);
        s.* = .{};
    }
```

`Scratch.deinit` resets the struct to empty, and `prepareLookup`
(`memo.zig:29`) allocates again when the slice is too short. So calling
`deinit` between searches is safe.

`src/search/nfa.zig:592`, the per-shard trim that already exists:

```zig
            if (self.shard_hits[s].capacity > 8192) self.shard_hits[s].clearAndFree(std.heap.c_allocator);
```

`src/app/app.zig:485-489`:

```zig
    pub fn clearInlineSearch(s: *AppState) void {
        s.search.clear();
        s.refreshInspector();
        app_sel.syncWatch(s);
    }
```

`src/bench.zig:421`:

```zig
    pOut(gpa, "after_search_mb={d:.2}\n", .{restedFootprintMb(&tester)});
```

Conventions: 600-line limit per file under `src/` (`mise exec -- zig build
lines`). No new comments. No Markdown edits except `plans/README.md`.
`Engine` methods that touch `searcher` lock `self.mutex` first; see
`runSearch` at `src/index/engine.zig:250-270`.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| All checks | `mise exec -- zig build check` | exit 0 |
| Bench | `mise exec -- zig build bench` | exit 0, prints `idle_mb=` and `after_search_mb=` |

The bench needs the user's real index and takes about 2 minutes.

## Scope

**In scope**: `src/search/search.zig`, `src/search/memo.zig`, `src/index/engine.zig`, `src/app/app.zig`, `src/bench.zig`, `src/tests/search.zig`, `plans/README.md` (status row).

**Out of scope**: search ranking, tiers, and results. `src/search/nfa.zig` worker threads. `src/app/session.zig`.

## Git workflow

JJ workspace. Do not commit or move changes. Subject style:
`perf(zig): release search scratch when the search ends`.

## Steps

### Step 1: Measure the scratch

1. In `src/search/memo.zig`, add `pub fn bytes(s: *const Scratch) usize` that returns `name_lookup.len * 4 + bits.len + best.len * 2 + dir_hits.capacity * 4`.
2. In `src/bench.zig`, directly before the `after_search_mb` line, print `scratch_mb=` from `searcher.scratch.bytes()` with the same `pOut` call style, in MB with two decimals.
3. Run `mise exec -- zig build bench`. Record `idle_mb`, `scratch_mb`, and `after_search_mb`.

**Verify**: the output has a `scratch_mb=` line. If `scratch_mb` is below 5,
STOP and report the three numbers. The scratch is then not the cause.

### Step 2: Add the trim

1. In `src/search/search.zig`, add to `Searcher`: `pub fn trim(self: *Searcher) void { self.scratch.deinit(self.gpa); }`.
2. In `src/index/engine.zig`, add after `runSearch`:

```zig
    pub fn trimSearch(self: *Engine) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);
        self.searcher.trim();
    }
```

3. In `src/app/app.zig`, add `s.engine.trimSearch();` as the first line of `clearInlineSearch`.
4. In `src/bench.zig`, call `searcher.trim();` after the `scratch_mb` line and before the `after_search_mb` line.

**Verify**: `mise exec -- zig build check` → exit 0.

### Step 3: Test

Add to `src/tests/search.zig`: `test "searcher: trim frees the scratch and the next search gives the same hits"`. Use the fixture that the test at `src/tests/search.zig:124` builds (an index above the selective threshold). Run one multi-word query, copy the hit paths, expect `searcher.scratch.bytes() > 0`, call `searcher.trim()`, expect `searcher.scratch.bytes() == 0`, run the same query, and expect the same paths in the same order.

If the multi-word query leaves `bytes()` at 0, the query did not use the
scratch. Pick a two-word query whose first word matches many names, as in
the bench list (`src main`).

**Verify**: `mise exec -- zig build check` → exit 0.

### Step 4: Measure again

Run `mise exec -- zig build bench`.

**Verify**: `after_search_mb` is at most `idle_mb + 10`. Record the three
numbers in your report.

## Done criteria

- [ ] `mise exec -- zig build check` exits 0
- [ ] `mise exec -- zig build bench` exits 0 and `after_search_mb <= idle_mb + 10`
- [ ] `rg -n "trimSearch" src/app/app.zig` prints one match
- [ ] Only in-scope files changed
- [ ] `plans/README.md` status row updated, with the before and after numbers in the report

## STOP conditions

- `scratch_mb` is below 5 in Step 1.
- `after_search_mb` stays above `idle_mb + 10` after Step 2. Report the numbers. The remaining memory is then freed heap that `malloc` keeps, or search results. Do not add more trims.
- `engine.zig` exceeds 600 lines.
- An excerpt does not match the live file.

## Maintenance notes

- The first search after a trim allocates the scratch again. With 2.4 million entries that is a few megabytes and well under a millisecond.
- The 4 pool threads stay alive after a trim. Their stacks are 64 KB each.
- The baseline for comparison, 2026-11-26: `src main` 6.6 ms, `test spec ts` 12.1 ms, all one-word queries under 1 ms at limit 200. Search speed is not a problem at this index size, so no plan moves search off the UI thread.
