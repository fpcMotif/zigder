const std = @import("std");
const fmt = @import("../index/fmt.zig");
const index_read = @import("../index/read.zig");
const live_mod = @import("../index/live.zig");
const engine_mod = @import("../index/engine.zig");
const search_mod = @import("../search/search.zig");
const fs_entry = @import("../fs/entry.zig");
const quicklook = @import("../fs/quicklook.zig");
const support = @import("support.zig");

test "engine: Waker adapter fires only for watched directory and detaches cleanly" {
    const gpa = std.testing.allocator;
    const tmp = try support.TempDir.create("/tmp/zigder-wake");
    defer tmp.cleanup();
    const root = tmp.path();

    try support.sh("mkdir -p '{s}/dir_a' '{s}/dir_b' && printf '1' > '{s}/dir_a/a.txt' && printf '2' > '{s}/dir_b/b.txt'", .{ root, root, root, root });

    var idx_buf: [128]u8 = undefined;
    const idx_path = try std.fmt.bufPrint(&idx_buf, "{s}/wake.zidx", .{root});
    try support.buildRootedIndex(gpa, root, idx_path, 10);

    var eng = try engine_mod.Engine.initHeadlessWithIndex(gpa, idx_path);
    defer eng.deinit();

    var wake_count: usize = 0;
    const Counter = struct {
        fn bump(ctx: ?*anyopaque) void {
            const p: *usize = @ptrCast(@alignCast(ctx orelse return));
            p.* += 1;
        }
    };
    eng.setWaker(.{ .ctx = &wake_count, .wake = Counter.bump });

    var a_buf: [128]u8 = undefined;
    const dir_a = try std.fmt.bufPrint(&a_buf, "{s}/dir_a", .{root});
    var b_buf: [128]u8 = undefined;
    const dir_b = try std.fmt.bufPrint(&b_buf, "{s}/dir_b", .{root});

    eng.setUiWatch(dir_a, false);
    try support.sh("printf 'more' > '{s}/dir_b/new_b.txt'", .{root});
    eng.processEventsBatch(&.{.{ .path = dir_b, .flags = 0, .id = 11 }}, &.{});
    try std.testing.expectEqual(@as(usize, 0), wake_count);

    try support.sh("printf 'hit' > '{s}/dir_a/new_a.txt'", .{root});
    eng.processEventsBatch(&.{.{ .path = dir_a, .flags = 0, .id = 12 }}, &.{});
    try std.testing.expectEqual(@as(usize, 1), wake_count);

    eng.setWaker(null);
    const gen_before = eng.status().generation;
    try support.sh("printf 'two' > '{s}/dir_a/new_a2.txt'", .{root});
    eng.processEventsBatch(&.{.{ .path = dir_a, .flags = 0, .id = 13 }}, &.{});
    try std.testing.expectEqual(@as(usize, 1), wake_count);
    try std.testing.expect(eng.status().generation > gen_before);
}

test "engine: owned FolderTotals survive live index replacement" {
    const gpa = std.testing.allocator;
    const tmp = try support.TempDir.create("/tmp/zigder-ft");
    defer tmp.cleanup();
    const root = tmp.path();

    try support.sh("mkdir -p '{s}/dir_a' && printf 'hello' > '{s}/dir_a/a.txt'", .{ root, root });

    var p1: [128]u8 = undefined;
    const idx1 = try std.fmt.bufPrint(&p1, "{s}/one.zidx", .{root});
    try support.buildRootedIndex(gpa, root, idx1, 10);

    var eng = try engine_mod.Engine.initHeadlessWithIndex(gpa, idx1);
    defer eng.deinit();

    var ft = (try eng.folderTotals(gpa, root)) orelse return error.MissingFolderTotals;
    defer ft.deinit(gpa);

    try support.sh("mkdir -p '{s}/dir_c' && printf '99' > '{s}/dir_c/c.txt'", .{ root, root });
    var p2: [128]u8 = undefined;
    const idx2 = try std.fmt.bufPrint(&p2, "{s}/two.zidx", .{root});
    try support.buildRootedIndex(gpa, root, idx2, 10);

    var next_idx = try index_read.Index.load(idx2);
    const next_lv = live_mod.Live.init(gpa, next_idx) catch |err| {
        next_idx.deinit();
        return err;
    };
    eng.attachLive(next_lv);

    const a_tot = ft.find("dir_a") orelse return error.MissingEntry;
    try std.testing.expectEqual(@as(u64, 5), a_tot.bytes);
    try std.testing.expectEqual(@as(u64, 1), a_tot.items);
}

test "engine: recordChange updates known dir, skips unknown dir, and advances generation" {
    const gpa = std.testing.allocator;
    const tmp1 = try support.TempDir.create("/tmp/zigder-rec");
    defer tmp1.cleanup();
    const root = tmp1.path();
    const tmp2 = try support.TempDir.create("/tmp/zigder-ext");
    defer tmp2.cleanup();
    const outside = tmp2.path();

    try support.sh("mkdir -p '{s}/dir_a' && printf 'base' > '{s}/dir_a/keep.txt'", .{ root, root });
    try support.sh("printf 'ext' > '{s}/outside_only.txt'", .{outside});

    var idx_buf: [128]u8 = undefined;
    const idx_path = try std.fmt.bufPrint(&idx_buf, "{s}/rec.zidx", .{root});
    try support.buildRootedIndex(gpa, root, idx_path, 10);

    var eng = try engine_mod.Engine.initHeadlessWithIndex(gpa, idx_path);
    defer eng.deinit();

    var a_buf: [128]u8 = undefined;
    const dir_a = try std.fmt.bufPrint(&a_buf, "{s}/dir_a", .{root});
    try support.sh("mkdir -p '{s}/dir_a/sub' && printf 'deep' > '{s}/dir_a/sub/nested_rec.txt'", .{ root, root });

    const g0 = eng.status().generation;
    eng.recordChange(dir_a);
    try std.testing.expectEqual(g0 + 1, eng.status().generation);

    var res: search_mod.SearchResults = .{};
    defer res.deinit(gpa);
    try eng.runSearch(gpa, root, "nested_rec", null, 10, &res);
    try std.testing.expectEqual(@as(usize, 1), res.hits.items.len);

    eng.recordChange(outside);
    try std.testing.expectEqual(g0 + 2, eng.status().generation);
    try eng.runSearch(gpa, root, "outside_only", null, 10, &res);
    try std.testing.expectEqual(@as(usize, 0), res.hits.items.len);
}

test "engine: persistent Searcher serves searches across live index swaps" {
    const gpa = std.testing.allocator;
    const tmp = try support.TempDir.create("/tmp/zigder-swap");
    defer tmp.cleanup();
    const root = tmp.path();

    try support.sh("mkdir -p '{s}/work' && printf '1' > '{s}/work/alpha_item.txt'", .{ root, root });
    var p1: [128]u8 = undefined;
    const idx1 = try std.fmt.bufPrint(&p1, "{s}/s1.zidx", .{root});
    try support.buildRootedIndex(gpa, root, idx1, 10);

    var eng = try engine_mod.Engine.initHeadlessWithIndex(gpa, idx1);
    defer eng.deinit();

    var res: search_mod.SearchResults = .{};
    defer res.deinit(gpa);
    try eng.runSearch(gpa, root, "alpha_item", null, 10, &res);
    try std.testing.expectEqual(@as(usize, 1), res.hits.items.len);

    try support.sh("rm -f '{s}/work/alpha_item.txt' && printf '2' > '{s}/work/beta_item.txt'", .{ root, root });
    var p2: [128]u8 = undefined;
    const idx2 = try std.fmt.bufPrint(&p2, "{s}/s2.zidx", .{root});
    try support.buildRootedIndex(gpa, root, idx2, 10);

    var next_idx = try index_read.Index.load(idx2);
    const next_lv = live_mod.Live.init(gpa, next_idx) catch |err| {
        next_idx.deinit();
        return err;
    };
    eng.attachLive(next_lv);

    try eng.runSearch(gpa, root, "beta_item", null, 10, &res);
    try std.testing.expectEqual(@as(usize, 1), res.hits.items.len);
    try eng.runSearch(gpa, root, "alpha_item", null, 10, &res);
    try std.testing.expectEqual(@as(usize, 0), res.hits.items.len);
}

test "fs: loadFolder and InspectorPreview accept totals directly without Engine" {
    const gpa = std.testing.allocator;
    const tmp = try support.TempDir.create("/tmp/zigder-fs");
    defer tmp.cleanup();
    const root = tmp.path();

    try support.sh("mkdir -p '{s}/child_dir' && printf 'abcd' > '{s}/plain.txt'", .{ root, root });

    const cname = "child_dir";
    const items = try gpa.alloc(index_read.FolderTotalEntry, 1);
    items[0] = .{
        .name_off = 0,
        .name_len = cname.len,
        .totals = .{ .bytes = 987, .allocated = 4096, .items = 5, .visible = 3 },
    };
    const names = try gpa.dupe(u8, cname);
    var ft: index_read.FolderTotals = .{ .items = items, .names = names };
    defer ft.deinit(gpa);

    var listing = try fs_entry.loadFolder(gpa, root, &ft, .name, true, true, false);
    defer listing.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), listing.order.items.len);
    const dir_entry = listing.entries.items[listing.order.items[0]];
    try std.testing.expectEqualStrings(cname, listing.nameOf(dir_entry));
    try std.testing.expect((dir_entry.flags & fs_entry.FLAG_SIZE_KNOWN) != 0);
    try std.testing.expectEqual(@as(u64, 987), dir_entry.size);
    try std.testing.expectEqual(@as(u32, 3), dir_entry.dir_items);

    var child_buf: [128]u8 = undefined;
    const child_path = try std.fmt.bufPrint(&child_buf, "{s}/child_dir", .{root});
    const prev = quicklook.InspectorPreview.load(child_path, .{
        .bytes = 987,
        .allocated = 4096,
        .items = 5,
        .visible = 3,
    });
    try std.testing.expect(prev.valid);
    try std.testing.expect(prev.is_dir);
    try std.testing.expectEqual(@as(u64, 987), prev.size);
    try std.testing.expectEqual(@as(u64, 4096), prev.alloc);
    try std.testing.expectEqual(@as(u64, 3), prev.dir_items);
}

extern "c" fn usleep(usec: c_uint) c_int;

fn writeTestBytes(path: []const u8, data: []const u8) !void {
    var pbuf: [256]u8 = undefined;
    const pz = try std.fmt.bufPrintSentinel(&pbuf, "{s}", .{path}, 0);
    const c = struct {
        extern "c" fn open(p: [*:0]const u8, flags: c_int, ...) c_int;
        extern "c" fn write(fd: c_int, b: [*]const u8, n: usize) isize;
        extern "c" fn close(fd: c_int) c_int;
    };
    const fd = c.open(pz, 0x0601, @as(c_int, 0o644));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var at: usize = 0;
    while (at < data.len) {
        const w = c.write(fd, data.ptr + at, data.len - at);
        if (w <= 0) return error.WriteFailed;
        at += @intCast(w);
    }
}

test "safety: Index.load and FounderIndex.load reject overflowed headers and corrupt offset tables" {
    const gpa = std.testing.allocator;
    const tmp = try support.TempDir.create("/tmp/zigder-corrupt");
    defer tmp.cleanup();
    const root = tmp.path();

    try support.sh("mkdir -p '{s}/sub' && printf 'hello' > '{s}/sub/alpha.txt' && printf 'world' > '{s}/beta.txt'", .{ root, root, root });

    var valid_buf: [128]u8 = undefined;
    const valid_path = try std.fmt.bufPrint(&valid_buf, "{s}/valid.zidx", .{root});
    try support.buildRootedIndex(gpa, root, valid_path, 10);

    const mapped = try fmt.mmapFile(valid_path);
    defer fmt.unmapFile(mapped);
    const copy = try gpa.dupe(u8, mapped);
    defer gpa.free(copy);

    var bad_buf: [128]u8 = undefined;
    const bad_path = try std.fmt.bufPrint(&bad_buf, "{s}/bad.zidx", .{root});

    @memcpy(copy, mapped);
    std.mem.writeInt(u64, copy[8 + 5 * 8 ..][0..8], @as(u64, 1) << 40, .little);
    try writeTestBytes(bad_path, copy);
    try std.testing.expectError(error.InvalidIndex, index_read.Index.load(bad_path));

    @memcpy(copy, mapped);
    std.mem.writeInt(u64, copy[8 + 7 * 8 ..][0..8], @as(u64, 1) << 62, .little);
    try writeTestBytes(bad_path, copy);
    try std.testing.expectError(error.InvalidIndex, index_read.Index.load(bad_path));

    var ref_idx = try index_read.Index.load(valid_path);
    const name_off_pos = ref_idx.off[@backingInt(fmt.ZSec.name_off)];
    ref_idx.deinit();

    @memcpy(copy, mapped);
    std.mem.writeInt(u32, copy[name_off_pos..][0..4], 16, .little);
    std.mem.writeInt(u32, copy[name_off_pos + 4 ..][0..4], 4, .little);
    try writeTestBytes(bad_path, copy);
    try std.testing.expectError(error.InvalidIndex, index_read.Index.load(bad_path));

    try writeTestBytes(bad_path, mapped[0 .. mapped.len - 64]);
    try std.testing.expectError(error.TruncatedIndex, index_read.Index.load(bad_path));

    var eng = engine_mod.Engine.init(gpa);
    defer eng.deinit();
    try std.testing.expect(!eng.loadExistingSync(bad_path));

    var fhdr: [fmt.HDR]u8 = @splat(0);
    @memcpy(fhdr[0..8], fmt.MAGIC_FSIDX);
    std.mem.writeInt(u64, fhdr[8..16], @as(u64, 1) << 62, .little);
    var fbad_buf: [128]u8 = undefined;
    const fbad_path = try std.fmt.bufPrint(&fbad_buf, "{s}/bad_founder.bin", .{root});
    try writeTestBytes(fbad_path, &fhdr);
    try std.testing.expectError(error.InvalidIndex, fmt.FounderIndex.load(fbad_path));
}

test "safety: E2 setWaker(null) serializes with concurrent wakeUi and E3/H1 stop cancels active scan" {
    const gpa = std.testing.allocator;
    const tmp = try support.TempDir.create("/tmp/zigder-e2e3");
    defer tmp.cleanup();
    const root = tmp.path();

    try support.sh("mkdir -p '{s}/watched' && printf '1' > '{s}/watched/a.txt'", .{ root, root });

    var idx_buf: [128]u8 = undefined;
    const idx_path = try std.fmt.bufPrint(&idx_buf, "{s}/w.zidx", .{root});
    try support.buildRootedIndex(gpa, root, idx_path, 10);

    var eng = try engine_mod.Engine.initHeadlessWithIndex(gpa, idx_path);
    defer eng.deinit();

    const WakeProbe = struct {
        detached: std.atomic.Value(bool) = .init(false),
        after_detach: std.atomic.Value(usize) = .init(0),

        fn wake(ctx: ?*anyopaque) void {
            const p: *@This() = @ptrCast(@alignCast(ctx orelse return));
            if (p.detached.load(.acquire)) {
                _ = p.after_detach.fetchAdd(1, .monotonic);
            }
        }
    };
    var probe: WakeProbe = .{};
    eng.setWaker(.{ .ctx = &probe, .wake = WakeProbe.wake });
    var wdir_buf: [128]u8 = undefined;
    const wdir = try std.fmt.bufPrint(&wdir_buf, "{s}/watched", .{root});
    eng.setUiWatch(wdir, true);

    const Pump = struct {
        fn run(e: *engine_mod.Engine, dir: []u8, r: []const u8) void {
            for (0..40) |i| {
                var fbuf: [256]u8 = undefined;
                const fp = std.fmt.bufPrint(&fbuf, "{s}/watched/f_{d}.txt", .{ r, i }) catch return;
                writeTestBytes(fp, "x") catch {};
                e.processEventsBatch(&.{.{ .path = dir, .flags = 0, .id = 100 + i }}, &.{});
            }
        }
    };
    const pth = try std.Thread.spawn(.{}, Pump.run, .{ &eng, wdir, root });
    _ = usleep(1_000);
    eng.setWaker(null);
    probe.detached.store(true, .release);
    pth.join();
    try std.testing.expectEqual(@as(usize, 0), probe.after_detach.load(.acquire));

    var cancel_idx_buf: [128]u8 = undefined;
    const cancel_idx = try std.fmt.bufPrint(&cancel_idx_buf, "{s}/canceled.zidx", .{root});
    var eng2 = engine_mod.Engine.init(gpa);
    defer eng2.deinit();

    try eng2.startAsync(cancel_idx, null, "/System/Library", root, false);
    try std.testing.expectError(error.WorkerRunning, eng2.startAsync(cancel_idx, null, "/System/Library", root, false));
    _ = usleep(2_000);
    eng2.stop();
    try std.testing.expect(!eng2.status().indexing);
    try std.testing.expectError(error.OpenFailed, index_read.Index.load(cancel_idx));
}

test "engine: an oversized subtree stays out of the overlay and a full overlay requests a rebuild" {
    const gpa = std.testing.allocator;
    const tmp = try support.TempDir.create("/tmp/zigder-cap");
    defer tmp.cleanup();
    const root = tmp.path();
    try support.sh("mkdir -p '{s}/dir_a' && printf 'base' > '{s}/dir_a/keep.txt'", .{ root, root });

    var idx_buf: [128]u8 = undefined;
    const idx_path = try std.fmt.bufPrint(&idx_buf, "{s}/cap.zidx", .{root});
    try support.buildRootedIndex(gpa, root, idx_path, 10);
    var eng = try engine_mod.Engine.initHeadlessWithIndex(gpa, idx_path);
    defer eng.deinit();
    const lv = &eng.live.?;
    lv.overlay_limit = 2;

    try support.sh("mkdir -p '{s}/dir_a/sub' && cd '{s}/dir_a/sub' && touch f1 f2 f3 f4 f5", .{ root, root });
    var a_buf: [128]u8 = undefined;
    eng.recordChange(try std.fmt.bufPrint(&a_buf, "{s}/dir_a", .{root}));
    try std.testing.expectEqual(@as(usize, 1), lv.alive_overlay_count);

    try lv.putOverlay("/cap-test/one", 0, 1, 1, 1);
    try lv.putOverlay("/cap-test/two", 0, 1, 1, 1);
    try std.testing.expect(!lv.takeRebuildRequest(true));
    try std.testing.expect(lv.takeRebuildRequest(false));
}
