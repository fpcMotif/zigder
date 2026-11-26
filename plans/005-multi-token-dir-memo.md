# Plan 005: Multi-word search scores folders once, not once per entry

> **Executor instructions.** Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report. Do not improvise. When done, update the status row for this plan
> in `plans/README.md`.

> **Drift check.** Git does not track `zig/` yet. Plans 002 and 004
> changed `zig/search_bitmap.zig`, so a hash from planning time does not
> apply. Compare the "Current state" excerpts with the live code, and STOP on a
> mismatch. For `zig/search_nfa.zig` run
> `shasum -a 256 zig/search_nfa.zig | cut -c1-12` and expect `e3d5824c56aa`.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: plans/002-big-index-oracle-and-name-score-fix.md, plans/003-bench-app-real-search.md
- **Category**: perf
- **Planned at**: commit `63a384c` (before git tracked `zig/`), 2026-11-24

## Why this matters

A query with two or more words, such as `src main`, is the slowest search in
the app. For every candidate entry the code builds the full path string and
runs the fuzzy matcher over it. On a 2,076,700-entry index this costs 92 ms
for `src main` and 384 ms for `a e`, on the UI thread. The Rust original
avoids this with a per-folder memo ("DirMemo"). This plan ports that idea. A
prototype gave the same results as the reference search on 30 synthetic and
24 real queries, and these times (p50, limit 200):

| Query | Before | After |
|-------|--------|-------|
| `src main` | 92 ms | 11.7 ms |
| `a e` | 384 ms | 36 ms |
| `s m` | 329 ms | 26 ms |
| `test spec ts` | 226 ms | 24 ms |
| `main src lib` | 148 ms | 16 ms |
| `src main !node_modules` | 113 ms | 19 ms |
| `library caches com` | 78 ms | 9.7 ms |
| `users lib` | 63 ms | 9.1 ms |
| `config json` | 39 ms | 5.6 ms |
| `in:~/devv src main` | 31 ms | 10.5 ms |
| `zig build` | 13 ms | 3.0 ms |

## Current state

Here is how the search scores a multi-word query today. Each word is a "token". An entry
matches when every token matches its file name or the name of one of its
ancestor folders. The reference scorer is `Query.matchPath` in
`zig/query.zig`. Its score for a matching entry is:

- for each token that matches the file name: the token's name score, plus
- for each token that does not match the file name: three quarters of the
  best score of that token over the ancestor folder names
  (`@divTrunc(best * 3, 4)`).

The scan in `zig/search_nfa.zig` already produces, for every unique name that
matches at least one token, a `NameHitEntry`:

```zig
// zig/search_nfa.zig:16-23
pub const NameHitEntry = struct {
    id: u32,
    score: i16,
    max_tot: i32,
    bits: u8,
    is_dot: bool,
    is_app: bool,
};
```

`id` is the unique-name id. `bits` has bit `t` set when token `t` matches the
name. `score` is the sum of the name scores of those tokens.

The slow path is at the end of `runBitmapTier` in `zig/search_bitmap.zig`. It
runs for two or more positive tokens:

```zig
// zig/search_bitmap.zig (line numbers before plan 002: 352-360)
    const name_lookup = try gpa.alloc(i32, idx.u);
    defer gpa.free(name_lookup);
    @memset(name_lookup, std.math.minInt(i32));
    for (matched_names.items, 0..) |m, mi| name_lookup[m.id] = @intCast(mi);

    if (pos.len <= 1 and neg.len == 0) {
        try scanEntriesDirect(...);
        return;
    }
```

```zig
// zig/search_bitmap.zig, the per-entry path match that this plan bypasses
            const fp = idx.pathBuf(e, &pbuf) orelse continue;
            if (q.matchPath(fp, kv, sz, mt)) |sc| {
                const tot = sc + dprior[par_arr[e]] + baseline.rankTweaks(m.is_dot, m.is_app, kv, mt, now);
                try top.push(gpa, tot, e, walk.NONE);
            }
```

Directly above the `name_lookup` allocation is this block:

```zig
    if (pos.len == 0 and ok_entries <= 60_000) {
        for (matched_names.items) |m| {
            try emitSingleEntries(gpa, live, q, lo, hi, now, m.id, .{
                .score = m.score,
                .is_dot = m.is_dot,
                .is_app = m.is_app,
            }, neg, neg_cache, top);
        }
        return;
    }
```

Helpers this plan uses. All exist today:

- `zig/search_bitmap.zig`: `pub const TopK`, `pub fn dirHasNeg(gpa, idx, dir, neg, neg_cache)`,
  and `inline fn zoneOk(z, q)` (not `pub` yet).
- `zig/index_read.zig`: `Index.d` is the folder count and `Index.u` is the
  unique-name count. The file also provides `dirEntry()`, `dirParent()`,
  `entName()`, `parent()`, `dirPrior()`, `nameEntsOff()`, `nameEnts()`,
  `zones()`, `uname(id)`, and `unameWide(id)`.
- `zig/fuzzy_simd.zig`: `tokenScore(name, wide, mask, tok) ?i32`.
- `zig/index_fmt.zig`: `nameMask(name)`, `ZONE`.

Index invariant this plan relies on: `dirParent()[k] < k` for every folder
`k >= 1`. Folder 0 is the root. A check on the real index found 0 violations
across 391,916 folders, and the test index obeys the same rule.

Conventions: no comments in Zig sources. Each file stays within 600 lines.
`zig/search_nfa.zig` has 588 lines. Do not add lines to it.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Oracle tests | `mise exec -- zig build test -Dtest-filter="oracle"` | exit 0 |
| All tests | `mise exec -- zig build test` | exit 0 |
| Line limit | `mise exec -- zig build lines` | `N files, all within 600 lines` |
| Bench | `mise exec -- zig build bench` | exit 0 |

## Scope

**In scope**:
- `zig/search_memo.zig` (create)
- `zig/search_bitmap.zig`

**Out of scope** (do NOT touch):
- `zig/search_nfa.zig`, `zig/query.zig`, `zig/fuzzy_simd.zig`. The memo must
  reproduce their scores. It must not change them.
- Queries with an `ext:` filter. They keep the existing path. A prototype
  that sent them through the memo made `src main ext:zig` slower (128 µs to
  5.6 ms).

## Git workflow

- Do not commit, stage, or push. Git does not track `zig/` yet.

## Steps

### Step 1: Create `zig/search_memo.zig`

Create the file with exactly this content:

```zig
const std = @import("std");
const fmt = @import("index_fmt.zig");
const walk = @import("walk.zig");
const fuzzy = @import("fuzzy_simd.zig");
const query_mod = @import("query.zig");
const live_mod = @import("live.zig");
const baseline = @import("search_baseline.zig");
const search_nfa = @import("search_nfa.zig");
const bitmap_tier = @import("search_bitmap.zig");

pub const MEMO_MIN_ENTRIES: usize = 8_192;
const SELECTIVE_MAX: usize = 60_000;
const NO_SCORE: i16 = std.math.minInt(i16);

const DirMemo = struct {
    npos: usize,
    bits: []u8,
    best: []i16,

    fn deinit(m: *DirMemo, gpa: std.mem.Allocator) void {
        gpa.free(m.bits);
        gpa.free(m.best);
    }
};

fn buildDirMemo(
    gpa: std.mem.Allocator,
    live: *const live_mod.Live,
    pos: []const *const fuzzy.Token,
    matched: []const search_nfa.NameHitEntry,
    name_lookup: []const i32,
) !DirMemo {
    const idx = &live.base;
    const npos = pos.len;
    const bits = try gpa.alloc(u8, idx.d);
    errdefer gpa.free(bits);
    const best = try gpa.alloc(i16, idx.d * npos);
    errdefer gpa.free(best);
    const name_best = try gpa.alloc(i16, matched.len * npos);
    defer gpa.free(name_best);
    const name_done = try gpa.alloc(bool, matched.len);
    defer gpa.free(name_done);
    @memset(name_done, false);

    const de = idx.dirEntry();
    const dp = idx.dirParent();
    const en = idx.entName();
    if (idx.d > 0) {
        bits[0] = 0;
        @memset(best[0..npos], NO_SCORE);
    }
    for (1..idx.d) |k| {
        const p = dp[k];
        std.debug.assert(p < k);
        bits[k] = bits[p];
        @memcpy(best[k * npos ..][0..npos], best[p * npos ..][0..npos]);
        const mi_signed = name_lookup[en[de[k]]];
        if (mi_signed < 0) continue;
        const mi: usize = @intCast(mi_signed);
        const m = matched[mi];
        if (m.bits == 0) continue;
        const own = name_best[mi * npos ..][0..npos];
        if (!name_done[mi]) {
            const nm = idx.uname(m.id);
            const mask = fmt.nameMask(nm);
            const wide = idx.unameWide(m.id);
            for (pos, 0..) |tok, t| {
                own[t] = NO_SCORE;
                if (((m.bits >> @intCast(t)) & 1) == 0) continue;
                const sc = fuzzy.tokenScore(nm, wide, mask, tok) orelse continue;
                own[t] = @intCast(std.math.clamp(sc, std.math.minInt(i16) + 1, std.math.maxInt(i16)));
            }
            name_done[mi] = true;
        }
        bits[k] |= m.bits;
        for (best[k * npos ..][0..npos], own) |*b, o| b.* = @max(b.*, o);
    }
    return .{ .npos = npos, .bits = bits, .best = best };
}

pub fn scoreMultiToken(
    gpa: std.mem.Allocator,
    live: *const live_mod.Live,
    q: *const query_mod.Query,
    pos: []const *const fuzzy.Token,
    neg: []const *const fuzzy.Token,
    lo: usize,
    hi: usize,
    now: u32,
    neg_cache: *std.AutoHashMapUnmanaged(u32, bool),
    matched: []const search_nfa.NameHitEntry,
    ok_entries: usize,
    top: *bitmap_tier.TopK,
) !void {
    const idx = &live.base;
    const npos = pos.len;
    const all: u8 = @intCast((@as(u16, 1) << @intCast(npos)) - 1);

    const name_lookup = try gpa.alloc(i32, idx.u);
    defer gpa.free(name_lookup);
    @memset(name_lookup, std.math.minInt(i32));
    for (matched, 0..) |m, mi| name_lookup[m.id] = @intCast(mi);

    var memo = try buildDirMemo(gpa, live, pos, matched, name_lookup);
    defer memo.deinit(gpa);

    const ne_off = idx.nameEntsOff();
    const ne = idx.nameEnts();
    const en = idx.entName();
    const par = idx.parent();
    const dprior = idx.dirPrior();
    const has_size_filter = q.size_min != 0 or q.size_max != std.math.maxInt(u64);
    const has_mtime_filter = q.mtime_min != 0 or q.mtime_max != std.math.maxInt(u32);

    const Ctx = struct {
        gpa: std.mem.Allocator,
        live: *const live_mod.Live,
        q: *const query_mod.Query,
        neg: []const *const fuzzy.Token,
        neg_cache: *std.AutoHashMapUnmanaged(u32, bool),
        memo: *const DirMemo,
        par: []const u32,
        dprior: []const i8,
        all: u8,
        now: u32,
        has_size_filter: bool,
        has_mtime_filter: bool,
        top: *bitmap_tier.TopK,

        inline fn entry(c: *const @This(), e: u32, m: search_nfa.NameHitEntry) !void {
            const p = c.par[e];
            if ((m.bits | c.memo.bits[p]) != c.all) return;
            if (c.live.isDead(e)) return;
            const kv = c.live.kindOf(e);
            if (!c.q.kindOk(kv)) return;
            if (c.has_size_filter) {
                const sz = c.live.base.sizeOf(e);
                if (sz < c.q.size_min or sz > c.q.size_max) return;
            }
            const mt = c.live.mtimeOf(e);
            if (c.has_mtime_filter and (mt < c.q.mtime_min or mt > c.q.mtime_max)) return;
            var sc: i32 = m.score;
            const best = c.memo.best[p * c.memo.npos ..][0..c.memo.npos];
            for (best, 0..) |b, t| {
                if (((m.bits >> @intCast(t)) & 1) == 0) sc += @divTrunc(@as(i32, b) * 3, 4);
            }
            if (c.neg.len > 0 and try bitmap_tier.dirHasNeg(c.gpa, &c.live.base, p, c.neg, c.neg_cache)) return;
            const tot = sc + c.dprior[p] + baseline.rankTweaks(m.is_dot, m.is_app, kv, mt, c.now);
            try c.top.push(c.gpa, tot, e, walk.NONE);
        }
    };
    const ctx: Ctx = .{
        .gpa = gpa,
        .live = live,
        .q = q,
        .neg = neg,
        .neg_cache = neg_cache,
        .memo = &memo,
        .par = par,
        .dprior = dprior,
        .all = all,
        .now = now,
        .has_size_filter = has_size_filter,
        .has_mtime_filter = has_mtime_filter,
        .top = top,
    };

    if (ok_entries <= SELECTIVE_MAX) {
        for (matched) |m| {
            if (m.bits == 0) continue;
            for (ne[ne_off[m.id]..ne_off[m.id + 1]]) |e| {
                if (e < lo or e >= hi) continue;
                try ctx.entry(e, m);
            }
        }
        return;
    }

    const zones_arr = idx.zones();
    var a = lo;
    while (a < hi) {
        const end = @min(((a / fmt.ZONE) + 1) * fmt.ZONE, hi);
        if (!bitmap_tier.zoneOk(&zones_arr[a / fmt.ZONE], q)) {
            a = end;
            continue;
        }
        for (a..end) |ei| {
            const e: u32 = @intCast(ei);
            const mi = name_lookup[en[e]];
            if (mi < 0) continue;
            const m = matched[@intCast(mi)];
            if (m.bits == 0) continue;
            try ctx.entry(e, m);
        }
        a = end;
    }
}
```

What it does: one pass over the folders in id order copies the parent's memo
and merges the folder's own name. `bits[k]` is the set of tokens that match
folder `k` or an ancestor. `best[k * npos + t]` is the best score of token
`t` over those names. Then each entry needs two array reads, not a path
build.

### Step 2: Wire it into `zig/search_bitmap.zig`

1. Add the import below the other imports at the top of the file:

```zig
const search_memo = @import("search_memo.zig");
```

2. Change `inline fn zoneOk(` to `pub inline fn zoneOk(`.

3. In `runBitmapTier`, insert this block after the
   `if (pos.len == 0 and ok_entries <= 60_000) { ... }` block and before
   `const name_lookup = try gpa.alloc(i32, idx.u);`:

```zig
    if (pos.len >= 2 and q.exts.items.len == 0 and ok_entries > search_memo.MEMO_MIN_ENTRIES) {
        try search_memo.scoreMultiToken(gpa, live, q, pos, neg, lo, hi, now, neg_cache, matched_names.items, ok_entries, top);
        return;
    }
```

The two files import each other. Zig allows this.

**Verify**: `mise exec -- zig build test -Dtest-filter="oracle"` must exit 0, no `oracle mismatch` line.

**Verify**: `mise exec -- zig build test` must exit 0.

**Verify**: `mise exec -- zig build lines` must print `N files, all within 600 lines`.

### Step 3: Prove the test covers the new path

Temporarily change `sc += @divTrunc(@as(i32, b) * 3, 4);` to `sc += b;` in
`zig/search_memo.zig`.

**Verify**: `mise exec -- zig build test -Dtest-filter="selective threshold"`
must fail with `oracle mismatch` lines for multi-word queries such as
`query="pack e"`, `query="pack src ma"`, and `query="src ma !util"`. The
prototype printed `expected 0, found 32` with the cache loop present. Without
that loop the count is lower.

Restore the line.

**Verify**: `mise exec -- zig build test` must exit 0.

### Step 4: Measure

Run `mise exec -- zig build bench`.

**Verify**: exit 0. In the `app query (limit 200)` table, the rows
`src main`, `zig build`, `config json`, `test spec ts`, and
`in:~/devv src main` each have a p50 at most half of the plan 003 baseline.
The one-word rows are within 20 percent of the baseline. Put both tables in
your report.

## Test plan

- No new test file. `zig/tests_search.zig` (from plan 002) already holds 16
  multi-word queries on an 88,800-entry index: with scope, negation, `kind:`,
  `size:`, three tokens, and one-letter tokens. Step 3 proves they reach the
  new code.
- The small oracle test in `zig/tests.zig` covers the path below 8,192
  entries, which this plan does not change.

## Done criteria

- [ ] `mise exec -- zig build test` exits 0
- [ ] `mise exec -- zig build lines` exits 0
- [ ] `mise exec -- zig build bench` exits 0 and the five multi-word rows are at most half of the baseline
- [ ] `zig/search_memo.zig` contains `@divTrunc(@as(i32, b) * 3, 4)` (Step 3 restored the original line)
- [ ] Only `zig/search_memo.zig` and `zig/search_bitmap.zig` changed
- [ ] `plans/README.md` status row updated

## STOP conditions

- An oracle test reports a mismatch after Step 2. Do not change the oracle,
  the query list, or `zig/query.zig`. Report the mismatch lines.
- The test in Step 3 does not fail. Then the test does not reach the memo.
  Report it.
- A debug test run hits the assertion `p < k`. The index invariant is false.
  Report it.
- A helper named in "Current state" does not exist or has another signature.
- The multi-word bench rows do not improve.

## Maintenance notes

- Extra memory per multi-word query: `d` bytes plus `2 * d * tokens` bytes for
  the memo, and `4 * u` bytes for the lookup. On the measured index (391,916
  folders, 663,491 names, two tokens) this is about 4.6 MB. The query frees
  it before returning.
- If `Query.matchPath` changes how it scores a token that matches a folder,
  `Ctx.entry` must change with it. The oracle test catches a mismatch.
- Entries added after the index build live in the overlay. `search.zig`
  scores them with `matchPath` in `searchOverlay`. The memo does not see them
  as ancestors. This is the same as before this plan.
- Deferred: `ext:` with several words still uses the per-entry path match. It
  is fast today because the extension filter leaves few names.
