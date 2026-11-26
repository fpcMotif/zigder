# Plan 011: The icon cache stores each distinct bitmap once and holds 8 MB

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
- **Depends on**: none
- **Category**: perf
- **Planned at**: commit `33844b4` plus the uncommitted working tree, 2026-11-26

## Why this matters

`IconCache` keys a folder icon by the folder's full path. Every plain folder
has the same picture, but each one gets its own bitmap. A 256-pixel icon is
262,144 bytes, so 25 folders in the icon view cost 6.5 MB for one picture.
A heap listing of the running app on 2026-11-26 showed 25 blocks of that
size. The cache holds up to 24 MB in the live generation and keeps the
retired generation too, so it can hold 48 MB. The app's peak target is
80 MB.

After this plan, equal bitmaps share one allocation, and the live generation
holds at most 8 MB.

## Current state

- `src/fs/media.zig` — `IconCache` (lines 93-138).
- `src/ui/file_icons.zig` — the only reader. It passes `px.key` to the UI as the image key.
- `src/tests/media.zig` — `MockIconCtx` and the `IconCache` test (lines 105-148).

`src/fs/media.zig:93-138`:

```zig
pub const IconCache = struct {
    gpa: std.mem.Allocator,
    live: std.AutoHashMapUnmanaged(u64, ?[]u8) = .empty,
    retired: std.AutoHashMapUnmanaged(u64, ?[]u8) = .empty,
    live_bytes: usize = 0,
    live_bytes_max: usize = 24 * 1024 * 1024,
    rasterizer: Rasterizer = .{},

    fn freeMap(gpa: std.mem.Allocator, map: *std.AutoHashMapUnmanaged(u64, ?[]u8)) void {
        var it = map.valueIterator();
        while (it.next()) |px| if (px.*) |bytes| gpa.free(bytes);
        map.deinit(gpa);
    }

    pub fn deinit(c: *IconCache) void {
        freeMap(c.gpa, &c.live);
        freeMap(c.gpa, &c.retired);
        c.live_bytes = 0;
    }

    pub fn beginFrame(c: *IconCache) void {
        if (c.live_bytes < c.live_bytes_max) return;
        freeMap(c.gpa, &c.retired);
        c.retired = c.live;
        c.live = .empty;
        c.live_bytes = 0;
    }

    pub fn lookup(c: *IconCache, full: []const u8, container: bool, pt: f32) ?IconPixels {
        if ((comptime nanoui.ui.portable) and c.rasterizer.icon == nativeIcon) return null;
        const side = sideForPt(pt);
        const key = cacheKey(full, container) ^ side;
        if (c.live.get(key)) |found| {
            const bytes = found orelse return null;
            return .{ .key = key, .bgra = bytes, .side = side };
        }
        const drawn = c.rasterizer.icon(c.rasterizer.ctx, c.gpa, full, side);
        c.live.put(c.gpa, key, drawn) catch {
            if (drawn) |bytes| c.gpa.free(bytes);
            return null;
        };
        const bytes = drawn orelse return null;
        c.live_bytes += bytes.len;
        return .{ .key = key, .bgra = bytes, .side = side };
    }
};
```

`src/ui/file_icons.zig:27-35`, the reader:

```zig
fn show(c: *ui.Context, icons: *fs_media.IconCache, full: []const u8, container: bool, pt: f32) bool {
    const px = icons.lookup(full, container, pt) orelse return false;
    return ui.image(c, .{
        .key = c.print("file-icon-{x}", .{px.key}),
        .source = .{ .pixels = .{ .bgra = px.bgra, .width = px.side, .height = px.side } },
        .box = .{ .w = pt, .h = pt },
        .radius = 0,
    });
}
```

The retired generation exists because the UI can still hold a pointer to a
bitmap for one frame after eviction. Keep that two-generation design.

`src/tests/media.zig:105-115`, the mock that every icon test uses. It fills
every bitmap with the same byte:

```zig
const MockIconCtx = struct {
    calls: usize = 0,

    fn draw(raw: ?*anyopaque, gpa: std.mem.Allocator, _: []const u8, side: u32) ?[]u8 {
        const ctx: *MockIconCtx = @ptrCast(@alignCast(raw orelse return null));
        ctx.calls += 1;
        const bytes = gpa.alloc(u8, @as(usize, side) * side * 4) catch return null;
        @memset(bytes, 0x42);
        return bytes;
    }
};
```

Conventions: 600-line limit per file (`media.zig` has 309). No new comments.
No Markdown edits except `plans/README.md`. Tests use
`std.testing.allocator`, which fails a test that leaks or frees twice.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| All checks | `mise exec -- zig build check` | exit 0 |
| Icon tests | `mise exec -- zig build test -Dtest-filter="IconCache"` | exit 0 |

## Scope

**In scope**: `src/fs/media.zig` (`IconCache` only), `src/tests/media.zig`, `plans/README.md` (status row).

**Out of scope**: `cacheKey`, `sideForPt`, `nativeIcon`, `src/ui/file_icons.zig`, and every view file. The signature of `lookup` and the fields of `IconPixels` stay the same.

## Git workflow

JJ workspace. Do not commit or move changes. Subject style:
`perf(zig): share equal icon bitmaps and cap the icon cache at 8 MB`.

## Steps

### Step 1: Make the existing mock draw distinct pixels

In `MockIconCtx.draw`, name the path parameter `full`. Keep
`@memset(bytes, 0x42);` and add after it
`std.mem.writeInt(u64, bytes[0..8], std.hash.Wyhash.hash(0, full), .little);`.
Each path then gets distinct pixels, so the existing test keeps its meaning
after Step 3.

**Verify**: `mise exec -- zig build test -Dtest-filter="IconCache"` → exit 0.

### Step 2: Write the failing test

Add a second mock, `SamePixelsCtx`, that is a copy of the old `MockIconCtx`
(constant fill `0x42`). Add
`test "media: IconCache stores equal bitmaps once"`:

1. Cache with `live_bytes_max = 1 << 20` and the `SamePixelsCtx` rasterizer.
2. `lookup("/a/dir1", true, 16)`, `lookup("/a/dir2", true, 16)`, `lookup("/a/dir3", true, 16)`.
3. Expect `mock.calls == 3`.
4. Expect `cache.live_bytes == 32 * 32 * 4`.
5. Expect the three results to have the same `bgra.ptr` and the same `key`.
6. Call `lookup("/a/dir1", true, 16)` again and expect `mock.calls == 3`.

**Verify**: `mise exec -- zig build test -Dtest-filter="stores equal bitmaps"` → FAILS at item 4 (it reports 12288). Do not continue until you see that failure.

### Step 3: Share the pixels

Change `IconCache` so that it has two levels per generation:

- `live: AutoHashMapUnmanaged(u64, ?u64)` — maps the path key to a content key, or null when the rasterizer returned nothing.
- `live_px: AutoHashMapUnmanaged(u64, []u8)` — maps the content key to the bitmap. It owns the bytes.
- `retired` and `retired_px` with the same types.

`lookup`:

1. Compute `key` as now. When `live` has it: null value → return null; otherwise return the bitmap from `live_px` with `.key` set to the content key.
2. Otherwise rasterize. On null, store null in `live` and return null.
3. Compute `content = std.hash.Wyhash.hash(side, bytes)`.
4. When `live_px` already has `content`, free the new bytes and use the stored ones. Otherwise put the new bytes in `live_px` and add their length to `live_bytes`.
5. Put `key → content` in `live`. On an allocation failure, leave both maps consistent: a bitmap that is in `live_px` stays owned by `live_px`.
6. Return `.{ .key = content, .bgra = stored, .side = side }`.

`beginFrame`: when `live_bytes >= live_bytes_max`, free `retired_px` bitmaps
and both retired maps, move `live` to `retired` and `live_px` to
`retired_px`, and reset `live_bytes`.

`deinit`: free the bitmaps of `live_px` and `retired_px`, then all four maps.

Change the default `live_bytes_max` to `8 * 1024 * 1024`.

**Verify**: `mise exec -- zig build test -Dtest-filter="IconCache"` → exit 0, both icon tests pass. Then `mise exec -- zig build check` → exit 0.

## Done criteria

- [ ] `mise exec -- zig build check` exits 0
- [ ] `rg -n "live_bytes_max: usize = 8 \* 1024 \* 1024" src/fs/media.zig` prints one match
- [ ] The test `media: IconCache stores equal bitmaps once` exists and passes
- [ ] The test `media: IconCache caches hits, respects eviction budget, and frees all pixels on deinit` passes with its assertions unchanged
- [ ] Only in-scope files changed
- [ ] `plans/README.md` status row updated

## STOP conditions

- The existing icon test needs a changed assertion to pass. Only the mock's fill may change.
- `std.testing.allocator` reports a leak or a double free that you cannot fix in two attempts.
- A view file needs an edit.
- An excerpt does not match the live file.

## Maintenance notes

- The image key that the UI sees is now the content key. Equal icons then share one slot in the UI's image atlas too.
- Each new folder path still costs one `iconForFile:` call on the UI thread. This plan removes the memory cost, not that time. If scrolling a folder of many folders hitches, measure `nativeIcon` before changing it.
- A review must check the out-of-memory path in `lookup`: no bitmap may be freed while a map still points to it.
