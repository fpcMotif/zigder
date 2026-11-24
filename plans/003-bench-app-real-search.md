# Plan 003: The bench reports search the way the app runs it

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report. Do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `zig/` is not tracked by git, so use a hash.
> Run `shasum -a 256 zig/bench.zig | cut -c1-12`. Expected: `0493295c3a5a`.
> On a different value, compare the "Current state" excerpts with the live
> code. On a mismatch, STOP.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: plans/001-restore-clean-build-config.md
- **Category**: perf
- **Planned at**: commit `63a384c` (`zig/` is untracked), 2026-11-24

## Why this matters

`zig build bench` measures ten one-word queries with a result limit of 50.
The app's inline search uses a limit of 200 (`zig/app.zig:435`), and users
type several words. The bench therefore reports 15 µs for `zigder` while the
app pays 117 µs for the same query, and it does not show that `src main`
takes 92 ms. Plans 004, 005, and 006 make those queries faster. This plan adds
report-only rows so each of those plans can show a before and an after number.
It adds no budget, so it cannot make the bench fail.

## Current state

- `zig/bench.zig` (421 lines) is the bench program. `zig build bench` builds
  and runs it against the real index of the machine at
  `~/Library/Caches/zigder/index.zidx`.

The existing query table is printed here:

```zig
// zig/bench.zig:383-392
    pOut(gpa, "{s:<18} | {s:>4} | {s:>4} | {s:>10} | {s:>10} | {s:>10} | {s:>8}\n", .{
        "query", "hits", "tier", "zig_p50_us", "zig_p95_us", "fnd_p50_us", "speedup",
    });
    for (qrows) |row| {
        pOut(gpa, "{s:<18} | {d:>4} | T{d:>3} | {d:>10.2} | {d:>10.2} | {d:>10.1} | {d:>7.1}x\n", .{
            row.query, row.hits, row.tier, row.zigder_p50_us, row.zigder_p95_us, row.founder_p50_us, row.speedup,
        });
    }

    const sub_p50_us = @max(
```

Names in scope at that point, all used earlier in the same function:
`gpa`, `home`, `live_ref` (the live index), `z_res` (a reusable
`search_mod.SearchResults`), `tester` (the offscreen UI), `measure`,
`query_mod`, `search_mod`, `pOut`, and `restedFootprintMb`.

The existing sampling pattern to copy:

```zig
// zig/bench.zig:321-328
        for (0..3) |_| try search_mod.search(gpa, live_ref, &q, null, &z_res);
        var z_samples: [25]f64 = undefined;
        for (&z_samples) |*slot| {
            const ts = measure.nanos();
            try search_mod.search(gpa, live_ref, &q, null, &z_res);
            slot.* = @as(f64, @floatFromInt(measure.nanos() - ts)) / 1000.0;
        }
        const z_stats = measure.Stats.of(&z_samples);
```

The footprint helper is used like this: `const list_10k_mb = restedFootprintMb(&tester.renderer);` (`zig/bench.zig:293`).

Conventions: no comments in Zig sources. Each file stays within 600 lines.

Reference numbers, measured on 2026-11-24 on a 2,076,700-entry index with a
limit of 200 and no cache (p50):

| Query | p50 |
|-------|-----|
| `zigder` | 117 µs |
| `nan` | 4,751 µs |
| `nano` | 2,435 µs |
| `con` | 2,009 µs |
| `src main` | 92 ms |
| `zig build` | 13 ms |
| `config json` | 39 ms |
| `test spec ts` | 226 ms |
| `in:~/devv src main` | 31 ms |
| `in:~/devv/zigder e` | 23 ms |

Another machine has another index, so its numbers differ.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Bench | `mise exec -- zig build bench` | exit 0, prints tables and a `{"budgets":[...]}` line |
| Line limit | `mise exec -- zig build lines` | `N files, all within 600 lines` |

`zig build bench` takes about one minute. It rewrites
`~/Library/Caches/zigder/index.zidx` when it converts the index. This is
existing behavior.

## Scope

**In scope**:
- `zig/bench.zig`

**Out of scope** (do NOT touch):
- The `metrics` array and the budgets. This plan adds no budget.
- The existing `bench_queries` table and the keystroke loop.

## Git workflow

- Do not commit, stage, or push. `zig/` is untracked.

## Steps

### Step 1: Record the baseline

Run `mise exec -- zig build bench` and save the output to a file outside the
repository, for example `/tmp/zigder-bench-before.txt`.

**Verify**: the output contains `=== zigder offscreen benchmark` and a `{"budgets":[` line.

### Step 2: Add the app-real table

In `zig/bench.zig`, insert this block after the `for (qrows) |row| { ... }`
loop and before `const sub_p50_us`:

```zig
    const app_queries = [_][]const u8{
        "zigder",
        "nan",
        "nano",
        "con",
        "e",
        "src main",
        "zig build",
        "config json",
        "test spec ts",
        "in:~/devv src main",
        "in:~/devv/zigder e",
        "ext:json",
        "kind:dir",
    };
    pOut(gpa, "\n{s:<22} | {s:>4} | {s:>4} | {s:>10} | {s:>10}\n", .{
        "app query (limit 200)", "hits", "tier", "p50_us", "p95_us",
    });
    for (app_queries) |qstr| {
        var aq = try query_mod.Query.parse(gpa, qstr, home);
        defer aq.deinit(gpa);
        aq.limit = 200;
        for (0..2) |_| try search_mod.search(gpa, live_ref, &aq, null, &z_res);
        var a_samples: [11]f64 = undefined;
        for (&a_samples) |*slot| {
            const ts = measure.nanos();
            try search_mod.search(gpa, live_ref, &aq, null, &z_res);
            slot.* = @as(f64, @floatFromInt(measure.nanos() - ts)) / 1000.0;
        }
        const a_stats = measure.Stats.of(&a_samples);
        pOut(gpa, "{s:<22} | {d:>4} | T{d:>3} | {d:>10.1} | {d:>10.1}\n", .{
            qstr, z_res.hits.items.len, z_res.tier_used, a_stats.p50, a_stats.p95,
        });
    }
    pOut(gpa, "after_search_mb={d:.2}\n", .{restedFootprintMb(&tester.renderer)});
```

This block was written from the patterns in the file. It was not compiled by
the plan author. If the compiler rejects a format specifier or a name, fix
only that token. If `search_mod.search` takes four arguments because plan 004
already ran, drop the `null` argument.

**Verify**: `mise exec -- zig build bench` → exit 0. The output contains the
header `app query (limit 200)`, 13 rows below it, and a line that starts with
`after_search_mb=`.

**Verify**: `mise exec -- zig build lines` → `N files, all within 600 lines`.

### Step 3: Save the new baseline

Save the output of Step 2 to `/tmp/zigder-bench-app-baseline.txt`. Put the 13
rows and the `after_search_mb` line in your final report. Plans 004 to 006
compare against them.

## Test plan

No unit test. The bench output is the check.

## Done criteria

- [ ] `mise exec -- zig build bench` exits 0 and prints the `app query (limit 200)` table with 13 rows
- [ ] The output contains `after_search_mb=`
- [ ] The `{"budgets":[...]}` line has the same eight names as in Step 1
- [ ] `mise exec -- zig build lines` exits 0
- [ ] Only `zig/bench.zig` changed
- [ ] `plans/README.md` status row updated

## STOP conditions

- `zig build bench` already fails in Step 1. Report the output. Do not edit.
- The bench fails a budget after Step 2 that passed in Step 1, on two runs in
  a row. The new block must not change the budgeted numbers.
- A row needs more than a token-level fix to compile.

## Maintenance notes

- Rows with 0 hits are valid on a machine without the folders `~/devv` or
  `~/devv/zigder`. They still run the scope lookup.
- After plans 004 to 006 land, a later change can add budgets for `src main`
  and `nan`. Take the budget values from three bench runs on the target
  machine, not from the table in this plan.
