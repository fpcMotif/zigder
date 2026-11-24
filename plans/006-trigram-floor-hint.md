# Plan 006: A fuzzy one-word search reuses the score floor that its trigram pass found

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report. Do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `zig/` is not tracked by git. Plans 002, 004,
> and 005 changed the two files in scope, so a hash from planning time does
> not apply. Compare the "Current state" excerpts with the live code. On a
> mismatch, STOP.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: MED (the synthetic oracle test does not reach this path yet, see Step 4)
- **Depends on**: plans/002-big-index-oracle-and-name-score-fix.md, plans/003-bench-app-real-search.md, plans/004-remove-search-cache.md
- **Category**: perf
- **Planned at**: commit `63a384c` (`zig/` is untracked), 2026-11-24

## Why this matters

A one-word fuzzy query of three or more letters first runs the "trigram
tier": it scores only the names that contain every three-letter piece of the
word. When that pass cannot prove its result complete, the code throws the
result away and runs the full name scan from zero. The discarded result
already holds `limit` real hits, so its lowest score is a valid lower bound
(a "floor") for the final answer. Passing that floor to the full scan lets it
skip most names. A prototype on a 2,076,700-entry index with a limit of 200
measured `nan` at 367 µs (was 4,751 µs) and `nano` at 187 µs (was 2,435 µs),
with results equal to the reference search. `con` and `rea` did not change.

## Current state

- `zig/search.zig`: `searchBase` runs the tiers in order.
- `zig/search_bitmap.zig`: `runBitmapTier` is the full scan. It already
  computes a "seed floor" and gives it to the scan.

In `searchBase`, after plan 004:

```zig
// zig/search.zig (inside searchBase)
    if (pos.len == 1 and pos[0].text.len >= 3) {
        const tok = pos[0];
        const done = try tryTrigramTier(gpa, live, q, tok, neg, &allow_ext, lo, hi, now, &neg_dir_cache, top);
        if (done) return 1;
        top.items.clearRetainingCapacity();
        top.floor = 0;
        top.floor_score = std.math.minInt(i32);
        top.full = false;
    }
```

`tryTrigramTier` calls `top.compact()` before it returns. After that,
`top.full` is true when `top` holds at least `limit` hits, and
`top.floor_score` is the score of the hit at position `limit`. Each name is
emitted once, and the scores use the same formula as the full scan.

The end of `searchBase`, after plan 004:

```zig
    try bitmap_tier.runBitmapTier(
        gpa,
        live,
        q,
        pos,
        neg,
        &allow_ext,
        lo,
        hi,
        now,
        &neg_dir_cache,
        top,
    );
    return 2;
```

In `runBitmapTier`, after plan 004:

```zig
// zig/search_bitmap.zig (inside runBitmapTier)
    top: *TopK,
) !void {
...
    const seed_floor = if (pos.len == 1)
        try computeSeedFloor(gpa, live, q, pos[0], neg, allow_ext, lo, hi, now, neg_cache)
    else
        std.math.minInt(i32);
```

`computeSeedFloor` returns `std.math.minInt(i32)` when it has no floor. The
scan drops only names whose best possible total is below the floor, so a
floor that real hits reach is safe.

Conventions: no comments in Zig sources. Each file stays within 600 lines.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Oracle tests | `mise exec -- zig build test -Dtest-filter="oracle"` | exit 0 |
| All tests | `mise exec -- zig build test` | exit 0 |
| Line limit | `mise exec -- zig build lines` | `N files, all within 600 lines` |
| Bench | `mise exec -- zig build bench` | exit 0 |

## Scope

**In scope**:
- `zig/search.zig`
- `zig/search_bitmap.zig`
- `zig/tests_search.zig` (added queries only)

**Out of scope** (do NOT touch):
- `tryTrigramTier` itself and its "escape" logic.
- `computeSeedFloor`.
- `zig/search_nfa.zig`.

## Git workflow

- Do not commit, stage, or push. `zig/` is untracked.

## Steps

### Step 1: Add fuzzy three-letter queries to the oracle test

In `zig/tests_search.zig`, add these entries to the end of the `queries`
array:

```zig
        "mai",
        "main",
        "rep",
        "bet",
        "in:/pack_007 mai",
        "mai kind:file",
```

**Verify**: `mise exec -- zig build test -Dtest-filter="selective threshold"` → exit 0. The new queries pass before the change.

### Step 2: Keep the floor in `searchBase`

In `zig/search.zig`, change the trigram block to:

```zig
    var floor_hint: i32 = std.math.minInt(i32);
    if (pos.len == 1 and pos[0].text.len >= 3) {
        const tok = pos[0];
        const done = try tryTrigramTier(gpa, live, q, tok, neg, &allow_ext, lo, hi, now, &neg_dir_cache, top);
        if (done) return 1;
        if (top.full) floor_hint = top.floor_score;
        top.items.clearRetainingCapacity();
        top.floor = 0;
        top.floor_score = std.math.minInt(i32);
        top.full = false;
    }
```

Add `floor_hint,` as the last argument of the `bitmap_tier.runBitmapTier(...)` call.

### Step 3: Use the floor in `runBitmapTier`

In `zig/search_bitmap.zig`, add the parameter `floor_hint: i32,` after
`top: *TopK,`. Change the seed floor to:

```zig
    const seed_floor = if (pos.len == 1)
        @max(floor_hint, try computeSeedFloor(gpa, live, q, pos[0], neg, allow_ext, lo, hi, now, neg_cache))
    else
        std.math.minInt(i32);
```

**Verify**: `mise exec -- zig build test` → exit 0.

**Verify**: `mise exec -- zig build lines` → `N files, all within 600 lines`.

### Step 4: Prove the test guards the floor

Temporarily change `if (top.full) floor_hint = top.floor_score;` to
`if (top.full) floor_hint = top.floor_score + 40;`.

**Verify**: `mise exec -- zig build test -Dtest-filter="selective threshold"` → fails with at least one `oracle mismatch` line.

The plan author ran this check in a prototype on 2026-11-24. The test did
NOT fail. The synthetic index does not reach the path where the trigram pass
fills `limit` hits and then falls through. The floor was checked only against
the real index: 32 queries at limits 50 and 200, 0 mismatches.

If the test does not fail for you either, add names to `buildBigListings`
that make it fail before you accept the change. The path needs a fuzzy word
of three or more letters where at least 200 names contain all its trigrams,
and other names match it only as a scattered subsequence. If you cannot make
the test fail in two attempts, STOP. Restore Steps 2 and 3 to the original
code and report that the floor has no test guard.

Restore the line.

**Verify**: `mise exec -- zig build test` → exit 0.

### Step 5: Measure

Run `mise exec -- zig build bench`.

**Verify**: exit 0. In the `app query (limit 200)` table the rows `nan` and
`nano` are at most half of the plan 003 baseline. No row is more than 20
percent slower. Put both tables in your report.

## Test plan

- Six added queries in `zig/tests_search.zig` (Step 1).
- Step 4 is the mutation check for the new floor.

## Done criteria

- [ ] `mise exec -- zig build test` exits 0
- [ ] `mise exec -- zig build lines` exits 0
- [ ] `mise exec -- zig build bench` exits 0, with `nan` and `nano` at most half of the baseline
- [ ] `zig/search.zig` contains `if (top.full) floor_hint = top.floor_score;` with no `+ 40`
- [ ] Only the three in-scope files changed
- [ ] `plans/README.md` status row updated

## STOP conditions

- Plan 004 did not run and `runBitmapTier` still has `out_cache_ids`. Stop and
  ask whether to run plan 004 first.
- An oracle test reports a mismatch after Step 3.
- `nan` and `nano` do not improve in the bench.

## Maintenance notes

- The floor is valid only because the trigram pass and the full scan use the
  same score formula (`scoreNameSingle` plus `emitSingleEntries`). A change to
  one of them must keep the other equal, or the hint must go.
- `con` and `rea` stay near 2 ms and 0.9 ms. Their trigram pass does not fill
  `limit` hits with a useful floor. A further fix needs a different idea.
