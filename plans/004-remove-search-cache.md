# Plan 004: Inline search no longer uses `SearchCache`

> **Executor instructions.** Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report. Do not improvise. When done, update the status row for this plan
> in `plans/README.md`.

> **Drift check.** Git does not track `zig/` yet, so use hashes.
> Run `shasum -a 256 zig/search.zig zig/engine.zig zig/app.zig zig/cli.zig | cut -c1-12`.
> Expected: `da92c5a92c6c`, `ff48be225ab6`, `fca0cb727be3`, `bf9a01c5d5b5`.

> Plans 002 and 003 changed `zig/search_bitmap.zig`, `zig/tests.zig`, and `zig/bench.zig`.
> Compare the "Current state" excerpts with the live code, and STOP on a mismatch.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: plans/002-big-index-oracle-and-name-score-fix.md, plans/003-bench-app-real-search.md
- **Category**: perf
- **Planned at**: commit `63a384c` (before git tracked `zig/`), 2026-11-24

## Why this matters

`SearchCache` keeps the matched name ids of the last one-word query, so the
next keystroke can filter that list. We measured it on a 2,076,700-entry
index at the app limit of 200. It slowed every measured keystroke. One cached
one-letter query also raised the process footprint from 2.55 MB to 22.95 MB
for the rest of the session.

| Keystroke | With cache (p50) | Without cache (p50) |
|-----------|------------------|---------------------|
| `z` | 1,281 µs | 104 µs |
| `zi` | 837 µs | 282 µs |
| `zig` | 2,081 µs | 137 µs |
| `n` | 15,286 µs | 226 µs |
| `na` | 8,751 µs | 530 µs |
| `c` | 17,819 µs | 421 µs |
| `co` | 9,330 µs | 296 µs |
| `con` | 2,950 µs | 2,009 µs |
| `nanoui` | 2,221 µs | 865 µs |

Cause: when a caller passes a cache, the search turns off its "seed floor" (an
early score bound that lets the scan skip most names). It then collects and
sorts the full match list. A list over 16,384 names is not stored, so the
work is thrown away. The scan buffers keep their peak size. Removing the cache
makes inline search faster, lowers memory, and deletes about 130 lines.

## Current state

Files and their role:

- `zig/search.zig` (566 lines). Defines `SearchCache` (lines 48-152) and the
  entry point `search`. `searchBase` and `tryTrigramTier` take the cache.
- `zig/search_bitmap.zig`. `runBitmapTier` takes `out_cache_ids`.
- `zig/engine.zig`. `Engine.runSearch` passes the cache through.
- `zig/app.zig`. `AppState.search_cache` is the only real cache.
- `zig/tests.zig`, `zig/tests_search.zig`, `zig/tests_state.zig`, `zig/bench.zig`, `zig/cli.zig`. Callers.

All uses, found by a search for `SearchCache|search_cache` in `zig/` on
2026-11-24:

```text
zig/search.zig:48    pub const SearchCache = struct {
zig/search.zig:166   cache: ?*SearchCache,            (fn search)
zig/search.zig:263   cache: ?*SearchCache,            (fn searchBase)
zig/search.zig:385   cache: ?*SearchCache,            (fn tryTrigramTier)
zig/engine.zig:204   cache: ?*search_mod.SearchCache, (fn runSearch)
zig/app.zig:116      search_cache: search_mod.SearchCache = .{},
zig/app.zig:163      s.search_cache.deinit(s.gpa);
zig/app.zig:435      s.engine.runSearch(s.gpa, s.home, txt, scope, 200, &s.search_cache, &s.search_results) catch {};
zig/tests.zig:201    var cache: search_mod.SearchCache = .{};
zig/bench.zig:356    var cache: search_mod.SearchCache = .{};
zig/STATE_MACHINES.md:77 and :283   (documentation)
```

Callers that pass `null` today:

```text
zig/app.zig:484          s.engine.runSearch(s.gpa, s.home, txt, null, 25, null, &s.modal_results) catch {};
zig/tests_state.zig:413  try engine.runSearch(gpa, env.root(), "latecomer", null, 10, null, &res);
zig/tests_state.zig:420  try engine.runSearch(gpa, env.root(), "latecomer", null, 10, null, &res);
zig/tests_state.zig:427  try engine.runSearch(gpa, env.root(), "afterdrop", null, 10, null, &res);
zig/tests.zig:246, :252  try search_mod.search(gpa, &live, &q2, null, &res);
zig/bench.zig:321, :325  try search_mod.search(gpa, live_ref, &q, null, &z_res);
zig/cli.zig:231          try search_mod.search(gpa, &live, &q, null, &res);
```

Excerpts to confirm before editing:

```zig
// zig/search.zig:162-168
pub fn search(
    gpa: std.mem.Allocator,
    live: *const live_mod.Live,
    q: *const query_mod.Query,
    cache: ?*SearchCache,
    out: *SearchResults,
) !void {
```

```zig
// zig/search.zig:278-293 (inside searchBase)
    if (pos.len == 1 and neg.len == 0) {
        if (cache) |c| {
            if (c.matchesNarrowing(live, q, pos[0], lo, hi)) {
                var next_ids: std.ArrayList(u32) = .empty;
                defer next_ids.deinit(gpa);
                for (c.name_ids.items) |kid| {
                    if (scoreNameSingle(idx, q, pos[0], neg, &allow_ext, kid)) |ns| {
                        try next_ids.append(gpa, kid);
                        try bitmap_tier.emitSingleEntries(gpa, live, q, lo, hi, now, kid, ns, neg, &neg_dir_cache, top);
                    }
                }
                c.store(gpa, live, q, pos[0], lo, hi, next_ids.items);
                return 0;
            }
        }
    }
```

```zig
// zig/search.zig:320-341 (end of searchBase)
    var cache_ids: std.ArrayList(u32) = .empty;
    defer cache_ids.deinit(gpa);
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
        if (cache != null) &cache_ids else null,
    );
    if (cache) |c| {
        if (pos.len == 1 and neg.len == 0 and cache_ids.items.len > 0 and cache_ids.items.len <= 16_384) {
            c.store(gpa, live, q, pos[0], lo, hi, cache_ids.items);
        }
    }
    return 2;
```

```zig
// zig/search.zig:429-431 and 446-462 (inside tryTrigramTier)
    var matched_ids: std.ArrayList(u32) = .empty;
    defer matched_ids.deinit(gpa);
    const collect_cache = cache != null and neg.len == 0 and tok.mode != .fuzzy;
...
        if (scoreNameSingle(idx, q, tok, neg, allow_ext, kid)) |ns| {
            if (collect_cache and matched_ids.items.len <= 16_384) {
                try matched_ids.append(gpa, kid);
            }
            try bitmap_tier.emitSingleEntries(gpa, live, q, lo, hi, now, kid, ns, neg, neg_cache, top);
        }
    }
    top.compact();

    if (tok.mode != .fuzzy) {
        if (cache) |c| {
            if (neg.len == 0 and matched_ids.items.len <= 16_384) {
                c.store(gpa, live, q, tok, lo, hi, matched_ids.items);
            }
        }
        return true;
    }
```

```zig
// zig/search_bitmap.zig, inside runBitmapTier (line numbers shift after plan 002)
    top: *TopK,
    out_cache_ids: ?*std.ArrayList(u32),
) !void {
...
    const seed_floor = if (pos.len == 1 and out_cache_ids == null)
        try computeSeedFloor(gpa, live, q, pos[0], neg, allow_ext, lo, hi, now, neg_cache)
    else
        std.math.minInt(i32);
...
    if (out_cache_ids) |cids| {
        if (pos.len == 1 and neg.len == 0 and seed_floor == std.math.minInt(i32) and matched_names.items.len <= 16_384) {
            try cids.ensureTotalCapacity(gpa, matched_names.items.len);
            for (matched_names.items) |m| cids.appendAssumeCapacity(m.id);
        }
    }
```

```zig
// zig/bench.zig:356-368
    var cache: search_mod.SearchCache = .{};
    defer cache.deinit(gpa);
    const keystrokes = [_][]const u8{ "z", "zi", "zig", "zigd", "zigde", "zigder" };
    var ks_samples: [keystrokes.len]f64 = undefined;
    for (keystrokes, 0..) |ks, ki| {
        var kq = try query_mod.Query.parse(gpa, ks, home);
        defer kq.deinit(gpa);
        kq.limit = 50;
        const ts = measure.nanos();
        try search_mod.search(gpa, live_ref, &kq, &cache, &z_res);
        ks_samples[ki] = @as(f64, @floatFromInt(measure.nanos() - ts)) / 1000.0;
    }
    const keystroke_last_us = ks_samples[ks_samples.len - 1];
```

Conventions: no comments in Zig sources. Each file stays within 600 lines.
The search returns a "tier" number in `SearchResults.tier_used`. Tier 0 meant
"answered from the cache". After this plan no search returns tier 0.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| All tests | `mise exec -- zig build test` | exit 0 |
| Oracle test | `mise exec -- zig build test -Dtest-filter="oracle"` | exit 0 |
| Line limit | `mise exec -- zig build lines` | `N files, all within 600 lines` |
| Bench | `mise exec -- zig build bench` | exit 0 |

## Scope

**In scope**:
- `zig/search.zig`
- `zig/search_bitmap.zig`
- `zig/engine.zig`
- `zig/app.zig`
- `zig/cli.zig`
- `zig/bench.zig`
- `zig/tests.zig`
- `zig/tests_search.zig`
- `zig/tests_state.zig` (three call sites only)

**Out of scope** (do NOT touch):
- `zig/live.zig` and its `epoch` field. Another session added it.
  Leave it even if nothing reads it after this plan. Report it.
- `zig/STATE_MACHINES.md`. This repository locks Markdown outside docs work.
  Report the stale lines 77 and 283 and the "Issue 4" row. Do not edit them.
- `zig/search_nfa.zig`.

## Git workflow

- Do not commit, stage, or push. Git does not track `zig/` yet.

## Steps

### Step 1: Remove the cache from `zig/search.zig`

1. Delete the whole `pub const SearchCache = struct { ... };` (lines 48-152).
2. In `pub fn search`, delete the parameter `cache: ?*SearchCache,` and the
   argument `cache,` in the call to `searchBase`.
3. In `fn searchBase`, delete the parameter `cache: ?*SearchCache,`.
4. Delete the narrowing block shown above (`if (pos.len == 1 and neg.len == 0) { if (cache) |c| { ... } }`).
5. In the call to `tryTrigramTier`, delete the argument `cache,`.
6. Replace the end of `searchBase` with:

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

7. In `fn tryTrigramTier`, delete the parameter `cache: ?*SearchCache,`, the
   three lines that declare `matched_ids` and `collect_cache`, and the
   `if (collect_cache ...) { ... }` block. Replace the non-fuzzy return with:

```zig
    if (tok.mode != .fuzzy) return true;
```

### Step 2: Remove `out_cache_ids` from `zig/search_bitmap.zig`

1. Delete the parameter `out_cache_ids: ?*std.ArrayList(u32),`.
2. Change the seed floor condition to `if (pos.len == 1)`.
3. Delete the `if (out_cache_ids) |cids| { ... }` block.

### Step 3: Update the callers

- `zig/engine.zig`: in `runSearch`, delete the parameter
  `cache: ?*search_mod.SearchCache,` and call `search_mod.search(gpa, lv, &q, out)`.
- `zig/app.zig`: delete the field at line 116 and the `deinit` at line 163.
  Line 435 becomes `s.engine.runSearch(s.gpa, s.home, txt, scope, 200, &s.search_results) catch {};`.
  Line 484 becomes `s.engine.runSearch(s.gpa, s.home, txt, null, 25, &s.modal_results) catch {};`.
- `zig/tests_state.zig`: at the three call sites, delete the second `null`
  (the argument before `&res`).
- `zig/cli.zig:231`: `try search_mod.search(gpa, &live, &q, &res);`
- `zig/tests.zig`: delete lines 201-202 (`var cache` and its `defer`). Change
  the three `search_mod.search` calls to four arguments.
- `zig/tests_search.zig`: delete the `for ([_]bool{ false, true }) |use_cache|`
  loop level and the two `cache` lines. Call
  `search_mod.search(gpa, &live, &q, &res)`. Remove `cache={}` and
  `use_cache` from the `std.debug.print` call.
- `zig/bench.zig`: delete the two `cache` lines. Change every
  `search_mod.search` call to four arguments. In the summary line, rename the
  label `keystroke_cached_us` to `keystroke_us`.

**Verify**: `mise exec -- zig build test` must exit 0.

**Verify**: `mise exec -- zig build test -Dtest-filter="oracle"` must exit 0, no `oracle mismatch` line.

### Step 4: Confirm nothing refers to the cache

Search `zig/` for the text `SearchCache`, `search_cache`, `out_cache_ids`,
and `collect_cache`.

**Verify**: the only matches are in `zig/STATE_MACHINES.md`.

**Verify**: `mise exec -- zig build lines` must print `N files, all within 600 lines`.

### Step 5: Measure

Run `mise exec -- zig build bench`.

**Verify**: exit 0. The line with `keystroke_us=` is present. Compare the
`app query (limit 200)` rows and `after_search_mb` with the baseline from
plan 003. The rows must not be slower by more than 20 percent. Put both
tables in your report.

## Test plan

- No new test. The two oracle tests (`zig/tests.zig` and
  `zig/tests_search.zig`) compare every query with the reference search.
  They must pass before and after.
- Step 3 removes the `use_cache` loop from `zig/tests_search.zig` along with the cache.

## Done criteria

- [ ] `mise exec -- zig build test` exits 0
- [ ] `mise exec -- zig build lines` exits 0
- [ ] `mise exec -- zig build bench` exits 0
- [ ] No Zig file under `zig/` contains `SearchCache`, `search_cache`, or `out_cache_ids`
- [ ] No files outside the in-scope list changed
- [ ] The report lists the stale lines in `zig/STATE_MACHINES.md`
- [ ] `plans/README.md` status row updated

## STOP conditions

- A new use of `SearchCache` exists that is not in the list above. Another
  session works on this code. Report the new use.
- An oracle test fails after the change. Do not edit the oracle.
- The bench shows an `app query` row more than 20 percent slower than the
  plan 003 baseline on two runs.
- `zig/tests_state.zig` fails for a reason other than the removed argument.

## Maintenance notes

- If a future change adds keystroke narrowing, it must keep the seed floor
  active and release its buffers. Measure it against the uncached numbers in
  this plan first.
- An earlier change added `Live.epoch` in `zig/live.zig` for this cache. After
  this plan nothing in search reads it. The owner of `zig/live.zig` can remove it.
- `tier_used == 0` no longer occurs. The bench prints tiers as `T1`, `T2`.
