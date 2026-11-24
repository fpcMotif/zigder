# Plan 002: Search is checked against an oracle on a large index, and scoped one-word search ranks by name again

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report. Do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `zig/` is not tracked by git, so use hashes.
> Run `shasum -a 256 zig/search_bitmap.zig zig/tests.zig | cut -c1-12`.
> Expected: `4cc7452265e1` and `f05497c1aaf2`. On a different value, compare
> the "Current state" excerpts with the live code. On a mismatch, STOP.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: plans/001-restore-clean-build-config.md
- **Category**: bug
- **Planned at**: commit `63a384c` (`zig/` is untracked), 2026-11-24

## Why this matters

The search engine has a slow, simple reference search (the "oracle") in the
tests. The fast search must return the same entries with the same scores. The
existing oracle test builds an index of about 75 entries. Three code paths in
`zig/search_bitmap.zig` run only when more than 60,000 entries match, so no
test reaches them. One of them has a ranking bug: a one-word search inside a
folder scope that matches most entries ranks the results without the name
score. On the real 2,076,700-entry index, the query `in:~/devv/zigder e`
returned 50 of 50 wrong results. This plan adds a test with an 88,800-entry
synthetic index, then fixes the bug. The same change stops a sort of up to
506,000 names that the buggy path did not need. That query went from 23 ms to
5.6 ms in a prototype.

## Current state

Files:

- `zig/search_bitmap.zig` (479 lines). The "bitmap tier" of the search.
  `runBitmapTier` scans all unique names, then turns matched names into
  entries. `scanEntriesDirect` walks every entry in a range.
- `zig/tests.zig` (326 lines). The test root. It holds `bruteForceSearch` (the
  oracle) and ends with a block that imports the other test files.
- `zig/index_build.zig`. `buildFromListings(listings, event_id, synced_at, home, dest_path)`
  builds an index file from in-memory folder listings.
- `zig/walk.zig`. Defines `Listing`, `KIND_DIR`, `KIND_FILE`, `NONE`.

The end of `zig/tests.zig`:

```zig
// zig/tests.zig:323-326
test {
    _ = @import("tests_ui.zig");
    _ = @import("tests_state.zig");
}
```

The buggy path. In `runBitmapTier`, a one-word query first sorts all matched
names, then picks a path:

```zig
// zig/search_bitmap.zig:314-339
    if (pos.len == 1) {
        if (matched_names.items.len > 1) {
            std.mem.sort(search_nfa.NameHitEntry, matched_names.items, {}, struct {
                fn lessThan(_: void, a: search_nfa.NameHitEntry, b: search_nfa.NameHitEntry) bool {
                    if (a.max_tot != b.max_tot) return a.max_tot > b.max_tot;
                    return a.id < b.id;
                }
            }.lessThan);
        }
        const range_len = hi - lo;
        if (ok_entries <= 60_000 or range_len >= ok_entries / 2 or (range_len > 250_000 and ok_entries <= 300_000)) {
            for (matched_names.items) |m| {
                if (top.full and m.max_tot < top.floor_score) break;
                try emitSingleEntries(gpa, live, q, lo, hi, now, m.id, .{
                    .score = m.score,
                    .is_dot = m.is_dot,
                    .is_app = m.is_app,
                }, neg, neg_cache, top);
                if ((!top.full and top.items.items.len >= top.k) or top.items.items.len >= @max(top.k + 16, 32)) {
                    top.compact();
                }
            }
            top.compact();
            return;
        }
    }
```

When that `if` is false (more than 60,000 matching entries and a scope range
smaller than half of them), the code reaches:

```zig
// zig/search_bitmap.zig:352-360
    const name_lookup = try gpa.alloc(i32, idx.u);
    defer gpa.free(name_lookup);
    @memset(name_lookup, std.math.minInt(i32));
    for (matched_names.items, 0..) |m, mi| name_lookup[m.id] = @intCast(mi);

    if (pos.len <= 1 and neg.len == 0) {
        try scanEntriesDirect(gpa, live, q, lo, hi, now, name_lookup, top);
        return;
    }
```

`scanEntriesDirect` uses the lookup only as a filter. The score has no name
part:

```zig
// zig/search_bitmap.zig:428-437
fn scanEntriesDirect(
    gpa: std.mem.Allocator,
    live: *const live_mod.Live,
    q: *const query_mod.Query,
    lo: usize,
    hi: usize,
    now: u32,
    name_lookup: ?[]const i32,
    top: *TopK,
) !void {
```

```zig
// zig/search_bitmap.zig:455-460
        for (a..end) |ei| {
            const e: u32 = @intCast(ei);
            const kid = en[e];
            if (name_lookup) |nl| {
                if (nl[kid] < 0) continue;
            }
```

```zig
// zig/search_bitmap.zig:474
            const tot = @as(i32, dprior[par[e]]) + baseline.rankTweaks(is_dot, is_app, kv, mt, now);
```

`name_lookup[kid]` is the position of name `kid` in `matched_names.items`, or
a negative number. `matched_names.items[i].score` is the name score. The
correct total is name score plus folder prior plus rank tweaks. The first call
of `scanEntriesDirect` (line 289, with `null`) is the no-token case, where the
name score is 0. That call is correct.

Conventions that apply:

- Zig sources in this repo contain no comments. Do not add any.
- Each file must stay within 600 lines. `zig build lines` enforces it.
- Tests use `std.testing.allocator` and a temporary folder from `mkdtemp`.
  See the test at `zig/tests.zig:162` for the pattern.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| One test | `mise exec -- zig build test -Dtest-filter="selective threshold"` | exit 0 |
| All tests | `mise exec -- zig build test` | exit 0 |
| Line limit | `mise exec -- zig build lines` | `N files, all within 600 lines` |

## Scope

**In scope**:
- `zig/tests_search.zig` (create)
- `zig/tests.zig` (one added line)
- `zig/search_bitmap.zig`

**Out of scope** (do NOT touch):
- `zig/search.zig`, `zig/search_nfa.zig`, `zig/live.zig`. Other plans own
  them, and another work session edits `search.zig` and `live.zig`.
- The oracle `bruteForceSearch`. It is the reference. Never change it to make
  a test pass.

## Git workflow

- Do not commit, stage, or push. `zig/` is untracked and the operator decides
  when it enters git.

## Steps

### Step 1: Add the large-index oracle test

Create `zig/tests_search.zig` with exactly this content:

```zig
const std = @import("std");
const walk = @import("walk.zig");
const index_read = @import("index_read.zig");
const index_build = @import("index_build.zig");
const query_mod = @import("query.zig");
const live_mod = @import("live.zig");
const search_mod = @import("search.zig");
const baseline = @import("search_baseline.zig");

extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
extern "c" fn system(cmd: [*:0]const u8) c_int;

fn bruteForceSearch(
    gpa: std.mem.Allocator,
    live: *const live_mod.Live,
    q: *const query_mod.Query,
    now: u32,
) !std.ArrayList(u64) {
    const idx = &live.base;
    const range = search_mod.scopeRange(idx, q.scope) orelse return .empty;
    var items: std.ArrayList(u64) = .empty;
    var pbuf: [2048]u8 = undefined;
    for (range[0]..range[1]) |ei| {
        const e: u32 = @intCast(ei);
        if (live.isDead(e)) continue;
        const fp = idx.pathBuf(e, &pbuf) orelse continue;
        const kv = live.kindOf(e);
        const sz = idx.sizeOf(e);
        const mt = live.mtimeOf(e);
        if (q.matchPath(fp, kv, sz, mt)) |sc| {
            const nm = idx.name(e);
            const is_dot = nm.len > 0 and nm[0] == '.';
            const is_app = std.mem.endsWith(u8, nm, ".app");
            const tot = sc + idx.dirPrior()[idx.parent()[e]] + baseline.rankTweaks(is_dot, is_app, kv, mt, now);
            const packed_sc: u64 = @intCast(@as(i64, tot) - @as(i64, std.math.minInt(i32)));
            try items.append(gpa, (packed_sc << 32) | (~e));
        }
    }
    std.mem.sort(u64, items.items, {}, std.sort.desc(u64));
    if (items.items.len > q.limit) items.shrinkRetainingCapacity(q.limit);
    return items;
}

fn addEnt(gpa: std.mem.Allocator, l: *walk.Listing, name: []const u8, kind: u8, size: u64, child: u32) !void {
    const off: u32 = @intCast(l.names.items.len);
    try l.names.appendSlice(gpa, name);
    try l.ents.append(gpa, .{
        .name_off = off,
        .name_len = @intCast(name.len),
        .kind = kind,
        .size = size,
        .alloc = 4096,
        .mtime = 1_700_000_000,
        .child = child,
    });
}

const BIG_PACKS: usize = 400;
const BIG_FILES: usize = 200;
const BIG_SRC_FILES: usize = 20;

fn buildBigListings(gpa: std.mem.Allocator) !std.ArrayList(walk.Listing) {
    var listings: std.ArrayList(walk.Listing) = .empty;
    errdefer {
        for (listings.items) |*l| l.deinit(gpa);
        listings.deinit(gpa);
    }
    try listings.append(gpa, .{ .id = 0 });
    for (0..BIG_PACKS) |p| try listings.append(gpa, .{ .id = @intCast(1 + p) });
    for (0..BIG_PACKS) |p| try listings.append(gpa, .{ .id = @intCast(1 + BIG_PACKS + p) });
    var nb: [64]u8 = undefined;
    for (0..BIG_PACKS) |p| {
        const pack_name = try std.fmt.bufPrint(&nb, "pack_{d:0>3}", .{p});
        try addEnt(gpa, &listings.items[0], pack_name, walk.KIND_DIR, 0, @intCast(1 + p));
        const pack = &listings.items[1 + p];
        try addEnt(gpa, pack, "src", walk.KIND_DIR, 0, @intCast(1 + BIG_PACKS + p));
        for (0..BIG_FILES) |j| {
            const name = switch (j % 8) {
                0 => try std.fmt.bufPrint(&nb, "e{d}", .{j}),
                1 => try std.fmt.bufPrint(&nb, "e{d}.txt", .{j}),
                2 => try std.fmt.bufPrint(&nb, "beta_{d}.md", .{j}),
                3 => try std.fmt.bufPrint(&nb, "The_File_{d}.zig", .{j}),
                4 => try std.fmt.bufPrint(&nb, "x{d}e", .{j}),
                5 => try std.fmt.bufPrint(&nb, ".env_{d}", .{j}),
                6 => try std.fmt.bufPrint(&nb, "report {d}.pdf", .{j}),
                else => try std.fmt.bufPrint(&nb, "Makefile_{d}", .{j}),
            };
            try addEnt(gpa, pack, name, walk.KIND_FILE, 10 * j, walk.NONE);
        }
        const src = &listings.items[1 + BIG_PACKS + p];
        for (0..BIG_SRC_FILES) |j| {
            const name = if (j % 2 == 0)
                try std.fmt.bufPrint(&nb, "main_{d}.zig", .{j})
            else
                try std.fmt.bufPrint(&nb, "util_{d}.rs", .{j});
            try addEnt(gpa, src, name, walk.KIND_FILE, 7 * j, walk.NONE);
        }
    }
    return listings;
}

test "searcher matches brute-force oracle on an index above the selective threshold" {
    const gpa = std.testing.allocator;
    var tmp: [64:0]u8 = @splat(0);
    const tmpl = "/tmp/zigder-big-XXXXXX";
    @memcpy(tmp[0..tmpl.len], tmpl);
    _ = mkdtemp(&tmp) orelse return error.TmpDir;
    const root = tmp[0..tmpl.len :0];
    defer {
        var cmd: [128]u8 = undefined;
        const s = std.fmt.bufPrintSentinel(&cmd, "rm -rf '{s}'", .{root}, 0) catch unreachable;
        _ = system(s);
    }

    var listings = try buildBigListings(gpa);
    defer {
        for (listings.items) |*l| l.deinit(gpa);
        listings.deinit(gpa);
    }
    var idx_path_buf: [128]u8 = undefined;
    const idx_path = try std.fmt.bufPrint(&idx_path_buf, "{s}/big.zidx", .{root});
    try index_build.buildFromListings(listings.items, 7, 1_700_000_000, "/nohome", idx_path);

    const idx = try index_read.Index.load(idx_path);
    var live = try live_mod.Live.init(gpa, idx);
    defer live.deinit();
    try std.testing.expect(live.base.n > 80_000);

    var res: search_mod.SearchResults = .{};
    defer res.deinit(gpa);

    const queries = [_][]const u8{
        "e",
        "in:/pack_007 e",
        "in:/pack_007 kind:file e",
        "in:/pack_007/src ma",
        "kind:dir",
        "ext:txt",
        "ext:zig main",
        "src main",
        "pack src main",
        "src main ext:zig",
        "src main !pack_003",
        "pack_00 util",
        "kind:dir src pack",
        "e !pack_003",
        "main !src",
        "beta",
        "^e",
        "report",
        "in:/pack_007 src main",
        "size:>1k src util",
        "pack e",
        "src ma",
        "pack e ext:txt",
        "pack e !pack_003",
        "in:/pack_007 pack e",
        "pack_00 e kind:file",
        "src ma !util",
        "pack src ma",
        "e x",
        "pack e size:<500",
    };
    const now = query_mod.nowSecs();
    var bad: usize = 0;
    for (queries) |qs| {
        for ([_]usize{ 15, 200 }) |limit| {
            for ([_]bool{ false, true }) |use_cache| {
                var q = try query_mod.Query.parse(gpa, qs, "/nohome");
                defer q.deinit(gpa);
                q.limit = limit;
                var cache: search_mod.SearchCache = .{};
                defer cache.deinit(gpa);
                try search_mod.search(gpa, &live, &q, if (use_cache) &cache else null, &res);
                var oracle = try bruteForceSearch(gpa, &live, &q, now);
                defer oracle.deinit(gpa);
                var same = oracle.items.len == res.hits.items.len;
                if (same) {
                    for (oracle.items, res.hits.items) |ok, got| {
                        const o_idx = ~@as(u32, @truncate(ok));
                        const o_sc: i32 = @intCast(@as(i64, @intCast(ok >> 32)) + @as(i64, std.math.minInt(i32)));
                        if (o_idx != got.idx or o_sc != got.score) {
                            same = false;
                            break;
                        }
                    }
                }
                if (!same) {
                    bad += 1;
                    std.debug.print("oracle mismatch: query=\"{s}\" limit={d} cache={} tier={d} oracle_len={d} got_len={d}\n", .{ qs, limit, use_cache, res.tier_used, oracle.items.len, res.hits.items.len });
                }
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), bad);
}
```

If plan 004 (remove the search cache) already ran, `search_mod.SearchCache`
no longer exists. In that case delete the `use_cache` loop, the two `cache`
lines, and the `cache={}` print field, and call
`search_mod.search(gpa, &live, &q, &res)`.

In `zig/tests.zig`, add one line to the last test block:

```zig
test {
    _ = @import("tests_ui.zig");
    _ = @import("tests_state.zig");
    _ = @import("tests_search.zig");
}
```

**Verify (the test must fail first)**:
`mise exec -- zig build test -Dtest-filter="selective threshold"` → exit code
not 0, with exactly these six lines and `expected 0, found 6`:

```text
oracle mismatch: query="in:/pack_007 e" limit=15 cache=true tier=2 oracle_len=15 got_len=15
oracle mismatch: query="in:/pack_007 e" limit=200 cache=false tier=2 oracle_len=200 got_len=200
oracle mismatch: query="in:/pack_007 e" limit=200 cache=true tier=2 oracle_len=200 got_len=200
oracle mismatch: query="in:/pack_007 kind:file e" limit=15 cache=true tier=2 oracle_len=15 got_len=15
oracle mismatch: query="in:/pack_007 kind:file e" limit=200 cache=false tier=2 oracle_len=200 got_len=200
oracle mismatch: query="in:/pack_007 kind:file e" limit=200 cache=true tier=2 oracle_len=200 got_len=200
```

This output was observed on the live tree on 2026-11-24. If other queries
mismatch, STOP and report the lines.

### Step 2: Add the name score to `scanEntriesDirect`

In `zig/search_bitmap.zig`, add this struct directly above `fn scanEntriesDirect`:

```zig
const MatchedNames = struct {
    lookup: []const i32,
    hits: []const search_nfa.NameHitEntry,
};
```

Change the parameter `name_lookup: ?[]const i32,` of `scanEntriesDirect` to
`matched: ?MatchedNames,`.

Replace the filter block inside the entry loop:

```zig
            if (name_lookup) |nl| {
                if (nl[kid] < 0) continue;
            }
```

with:

```zig
            var name_score: i32 = 0;
            if (matched) |mn| {
                const mi = mn.lookup[kid];
                if (mi < 0) continue;
                name_score = mn.hits[@intCast(mi)].score;
            }
```

Replace the total:

```zig
            const tot = name_score + @as(i32, dprior[par[e]]) + baseline.rankTweaks(is_dot, is_app, kv, mt, now);
```

Change the call inside `if (pos.len <= 1 and neg.len == 0)` to:

```zig
        try scanEntriesDirect(gpa, live, q, lo, hi, now, .{ .lookup = name_lookup, .hits = matched_names.items }, top);
```

The first call (`scanEntriesDirect(gpa, live, q, lo, hi, now, null, top)`)
stays as it is.

**Verify**: `mise exec -- zig build test -Dtest-filter="selective threshold"` → exit 0.

### Step 3: Sort the matched names only where the sort is used

Only the name-driven loop needs `matched_names` in `max_tot` order. Move the
sort inside that branch. The start of the `if (pos.len == 1)` block shown in "Current state" becomes:

```zig
    if (pos.len == 1) {
        const range_len = hi - lo;
        if (ok_entries <= 60_000 or range_len >= ok_entries / 2 or (range_len > 250_000 and ok_entries <= 300_000)) {
            if (matched_names.items.len > 1) {
                std.mem.sort(search_nfa.NameHitEntry, matched_names.items, {}, struct {
                    fn lessThan(_: void, a: search_nfa.NameHitEntry, b: search_nfa.NameHitEntry) bool {
                        if (a.max_tot != b.max_tot) return a.max_tot > b.max_tot;
                        return a.id < b.id;
                    }
                }.lessThan);
            }
            for (matched_names.items) |m| {
```

The rest of the loop does not change. Close the braces as before.

**Verify**: `mise exec -- zig build test` → exit 0.

**Verify**: `mise exec -- zig build lines` → `N files, all within 600 lines`.

## Test plan

- New test: `zig/tests_search.zig`, 30 queries, two limits, cache on and off,
  on an 88,800-entry index. It covers the scoped one-word path (the bug), the
  multi-word paths above 60,000 matches, negation, and filters.
- Pattern: `zig/tests.zig:162` ("searcher matches brute-force oracle and Live overlay updates").
- The test went red in Step 1 and must be green after Step 2.

## Done criteria

- [ ] `mise exec -- zig build test` exits 0
- [ ] `mise exec -- zig build test -Dtest-filter="selective threshold"` exits 0 and prints no `oracle mismatch` line
- [ ] `mise exec -- zig build lines` exits 0
- [ ] `zig/search_bitmap.zig` contains `name_score + @as(i32, dprior[par[e]])`
- [ ] Only the three in-scope files changed
- [ ] `plans/README.md` status row updated

## STOP conditions

- The excerpts in "Current state" do not match the live file.
- Step 1 fails with a different set of mismatch lines than the six listed.
- The test still fails after Step 2. Do not change the oracle or the query
  list. Report the mismatch lines.
- `zig build test` fails to compile in a file outside the scope. Another
  session is editing `zig/`. Report the first error.

## Maintenance notes

- Every later plan in this folder uses this test as its correctness gate. Add
  a query to its list when a new search path is added.
- The test builds its index in memory and takes a few seconds in Debug mode.
- Measured in a prototype on the real index: `in:~/devv/zigder e` went from
  50 of 50 wrong results at 23 ms to 0 wrong results at 5.6 ms.
