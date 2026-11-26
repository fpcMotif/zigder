const std = @import("std");
const measure = @import("measure.zig");
const walk = @import("index/walk.zig");
const fmt = @import("index/fmt.zig");
const index_read = @import("index/read.zig");
const index_build = @import("index/build.zig");
const fuzzy = @import("search/fuzzy_simd.zig");
const query_mod = @import("search/query.zig");
const live_mod = @import("index/live.zig");
const live_sync = @import("index/live_sync.zig");
const engine_mod = @import("index/engine.zig");
const search_mod = @import("search/search.zig");
const baseline = @import("search/baseline.zig");
const fsevents = @import("index/fsevents.zig");
const fs_entry = @import("fs/entry.zig");
const fs_undo = @import("fs/undo.zig");
const volumes = @import("fs/volumes.zig");
const quicklook = @import("fs/quicklook.zig");
const support = @import("tests/support.zig");
const search_tests = @import("tests/search.zig");

test "walk scan and buildFromListings roundtrip into ZSIDX001" {
    const gpa = std.testing.allocator;
    const tmp = try support.TempDir.create("/tmp/zigder-test");
    defer tmp.cleanup();
    const root = tmp.path();

    try support.sh(
        "mkdir -p '{s}/alpha/nested' '{s}/beta' && printf 'hello world' > '{s}/alpha/readme.md' && printf 'fn main() void {{}}' > '{s}/alpha/nested/main.zig' && printf 'data' > '{s}/beta/Cargo.toml'",
        .{ root, root, root, root, root },
    );

    var idx_path_buf: [128]u8 = undefined;
    const idx_path = try std.fmt.bufPrint(&idx_path_buf, "{s}/test.zidx", .{root});
    {
        var scanned = try walk.scan(gpa, root, &.{}, 2);
        defer scanned.deinit();
        try std.testing.expect(scanned.listings.items.len >= 4);
        try index_build.buildFromListings(scanned.listings.items, 42, 1700000000, root, idx_path);
    }

    var idx = try index_read.Index.load(idx_path);
    defer idx.deinit();

    try std.testing.expectEqual(@as(u64, 42), idx.event_id);
    try std.testing.expect(idx.n >= 6);
    try std.testing.expect(idx.d >= 4);

    const main_e = idx.lookup("/alpha/nested/main.zig") orelse return error.NotFound;
    var pbuf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("/alpha/nested/main.zig", idx.pathBuf(main_e, &pbuf).?);
    try std.testing.expectEqual(@as(u64, 17), idx.sizeOf(main_e));

    const tri = fmt.trigramId('m', 'a', 'i');
    const posts = idx.trigramSlice(tri);
    try std.testing.expect(posts.len >= 1);
    var found_main = false;
    for (posts) |kid| {
        if (std.mem.eql(u8, idx.uname(kid), "main.zig")) found_main = true;
    }
    try std.testing.expect(found_main);

    const tot = idx.totals("/alpha") orelse return error.TotalsMissing;
    try std.testing.expectEqual(@as(u64, 28), tot.bytes);
    try std.testing.expectEqual(@as(u64, 3), tot.items);
    try std.testing.expectEqual(@as(u64, 2), tot.visible);
    _ = measure.footprint();
}

test "fuzzyScore SIMD lane ordering matches across 16, 32, and 64 byte names" {
    const ref_len: usize = 65;
    var ref_buf: [ref_len]u8 = @splat('x');
    for ([_]usize{ 16, 32, 64 }) |len| {
        var buf: [64]u8 = @splat('x');
        for (0..len) |pos| {
            buf[pos] = if ((pos & 1) == 0) 'a' else 'A';
            ref_buf[pos] = buf[pos];
            const got = fuzzy.fuzzyScore(buf[0..len], "a") orelse return error.MissingMatch;
            const expected_ref = fuzzy.fuzzyScore(&ref_buf, "a") orelse return error.MissingMatch;
            const len_pen_diff = @divTrunc(@min(@as(i32, @intCast(ref_len)), 80), 3) - @divTrunc(@min(@as(i32, @intCast(len)), 80), 3);
            try std.testing.expectEqual(expected_ref + len_pen_diff, got);
            try std.testing.expectEqual(@as(?i32, null), fuzzy.fuzzyScore(buf[0..len], "z"));
            buf[pos] = 'x';
            ref_buf[pos] = 'x';
        }
    }
}

test "maxBrokenTrigramBound holds across gapped fuzzy pairs" {
    const names = [_][]const u8{
        "finder-fs",
        "native-gpui",
        "zigder_search_engine.zig",
        "MyCamelCaseDocument.pdf",
        "com.apple.Safari.plist",
        "application_support_cache",
        ".hidden_config_file",
        "a-b-c-d-e-f-g-h-i-j",
        "Cargo.toml",
        "package.json",
    };
    const queries = [_][]const u8{
        "fdrfs",
        "nngpui",
        "zdrsrch",
        "mccdoc",
        "casplist",
        "appsup",
        "hdncfg",
        "abcefg",
        "cgotml",
        "pkgjsn",
    };
    for (names) |nm| {
        for (queries) |q| {
            if (!fuzzy.hasAllTrigrams(nm, q)) {
                if (fuzzy.fuzzyScore(nm, q)) |sc| {
                    try std.testing.expect(sc <= fuzzy.maxBrokenTrigramBound(q));
                }
            }
        }
    }
}

test "searcher matches brute-force oracle and Live overlay updates" {
    const gpa = std.testing.allocator;
    const tmp = try support.TempDir.create("/tmp/zigder-oracle");
    defer tmp.cleanup();
    const root = tmp.path();

    try support.sh(
        "mkdir -p '{s}/src/ui' '{s}/apps/Safari.app' '{s}/docs' '{s}/node_modules/pkg' && " ++
            "for i in $(seq 1 60); do printf 'x' > '{s}/src/file_'$i'.zig'; done && " ++
            "printf 'main' > '{s}/src/main.zig' && " ++
            "printf 'readme' > '{s}/docs/README.md' && " ++
            "printf 'cfg' > '{s}/src/ui/config.json' && " ++
            "printf 'fdr' > '{s}/src/finder-fs.rs' && " ++
            "printf 'dot' > '{s}/.gitignore' && " ++
            "printf 'big' > '{s}/docs/archive_data.bin'",
        .{ root, root, root, root, root, root, root, root, root, root, root },
    );

    var idx_path_buf: [128]u8 = undefined;
    const idx_path = try std.fmt.bufPrint(&idx_path_buf, "{s}/oracle.zidx", .{root});
    try support.buildFlatIndex(gpa, root, idx_path, 100);

    const idx = try index_read.Index.load(idx_path);
    var live = try live_mod.Live.init(gpa, idx);
    defer live.deinit();

    var res: search_mod.SearchResults = .{};
    defer res.deinit(gpa);

    const queries = [_][]const u8{
        "file",
        "main.zig",
        "^main",
        "config$",
        "'README",
        "fdrfs",
        "src main",
        "file !node_modules",
        "ext:zig",
        "type:app Safari",
        "kind:dir docs",
        "in:/src config",
        "f",
        "fi",
        "fil",
        "file_",
    };
    const now = query_mod.nowSecs();
    var searcher = search_mod.Searcher.init(gpa);
    defer searcher.deinit();
    for (queries) |qs| {
        var q = try query_mod.Query.parse(gpa, qs, root);
        defer q.deinit(gpa);
        q.limit = 15;
        try searcher.search(gpa, &live, &q, &res);
        var oracle = try search_tests.bruteForceSearch(gpa, &live, &q, now);
        defer oracle.deinit(gpa);
        try std.testing.expectEqual(oracle.items.len, res.hits.items.len);
        for (oracle.items, res.hits.items) |ok, got| {
            try std.testing.expectEqual(baseline.unpackIdx(ok), got.idx);
            try std.testing.expectEqual(baseline.unpackScore(ok), got.score);
        }
    }

    try live.putOverlay("/src/fresh_live_file.zig", walk.KIND_FILE, 128, 4096, now);
    live.removePath("/src/main.zig");

    var q2 = try query_mod.Query.parse(gpa, "fresh_live", root);
    defer q2.deinit(gpa);
    try searcher.search(gpa, &live, &q2, &res);
    try std.testing.expectEqual(@as(usize, 1), res.hits.items.len);
    try std.testing.expectEqualStrings("/src/fresh_live_file.zig", res.pathOf(res.hits.items[0]));

    var q3 = try query_mod.Query.parse(gpa, "'main.zig", root);
    defer q3.deinit(gpa);
    try searcher.search(gpa, &live, &q3, &res);
    try std.testing.expectEqual(@as(usize, 0), res.hits.items.len);

    _ = fsevents.currentId();
}

test "fs_entry natural sort, loadFolder, fs_ops with undo/redo, tags, and InspectorPreview" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(std.math.Order.lt, fs_entry.naturalCmp("file2.txt", "file10.txt"));
    try std.testing.expectEqual(std.math.Order.lt, fs_entry.naturalCmp("Item 1", "item 20"));

    const tmp = try support.TempDir.create("/tmp/zigder-fsops");
    defer tmp.cleanup();
    const root = tmp.path();

    var undo: fs_undo.UndoStack = .{};
    defer undo.deinit(gpa);

    const sub = try undo.createFolder(gpa, root, "project");
    defer gpa.free(sub);

    const file1 = try undo.createFile(gpa, sub, "note.txt");
    defer gpa.free(file1);

    var dup_res = try undo.duplicateBatch(gpa, &.{file1});
    defer dup_res.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), dup_res.succeeded);
    var dup_buf: [256]u8 = undefined;
    const dup1 = try std.fmt.bufPrint(&dup_buf, "{s}/note copy.txt", .{sub});

    const renamed = try undo.renameItem(gpa, dup1, "renamed.txt");
    defer gpa.free(renamed);

    try std.testing.expect(volumes.writeTagMask(renamed, (1 << 0) | (1 << 4)));
    try std.testing.expectEqual(@as(u8, (1 << 0) | (1 << 4)), volumes.readTagMask(renamed));

    var listing = try fs_entry.loadFolder(gpa, sub, null, .name, true, true, false);
    defer listing.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), listing.order.items.len);
    const first_e = listing.entries.items[listing.order.items[0]];
    const second_e = listing.entries.items[listing.order.items[1]];
    try std.testing.expectEqualStrings("note.txt", listing.nameOf(first_e));
    try std.testing.expectEqualStrings("renamed.txt", listing.nameOf(second_e));
    try std.testing.expectEqual(@as(u8, (1 << 0) | (1 << 4)), second_e.tag_mask);

    const prev = quicklook.InspectorPreview.load(renamed, null);
    try std.testing.expect(prev.valid);
    try std.testing.expect(!prev.is_dir);

    var undo1 = try undo.undo(gpa);
    defer undo1.deinit(gpa);
    try std.testing.expectEqual(fs_undo.UndoStatus.ok, undo1.status);
    var undo2 = try undo.undo(gpa);
    defer undo2.deinit(gpa);
    try std.testing.expectEqual(fs_undo.UndoStatus.ok, undo2.status);
    var redo1 = try undo.redo(gpa);
    defer redo1.deinit(gpa);
    try std.testing.expectEqual(fs_undo.UndoStatus.ok, redo1.status);

    var ql: quicklook.QuickLook = .{ .gpa = gpa, .headless = true };
    defer ql.deinit();
    ql.toggle(&.{file1});

    const sb = try volumes.discoverSidebar(gpa, root);
    defer volumes.freeSidebar(gpa, sb);
    try std.testing.expect(sb.len >= 7);
}

test "InspectorPreview leaves the last-opened date for later while Spotlight warms up" {
    quicklook.spotlight_warming.store(true, .release);
    defer quicklook.spotlight_warming.store(false, .release);

    var preview = quicklook.InspectorPreview.load("/usr/bin", null);
    try std.testing.expect(preview.valid);
    try std.testing.expect(preview.last_opened_due);
    preview.finishLastOpened("/usr/bin");
    try std.testing.expect(preview.last_opened_due);

    quicklook.spotlight_warming.store(false, .release);
    preview.finishLastOpened("/usr/bin");
    try std.testing.expect(!preview.last_opened_due);
    try std.testing.expect(!quicklook.InspectorPreview.load("/usr/bin", null).last_opened_due);
}

test "fs_entry loadFolder reads every entry's tags in a folder large enough for parallel reads" {
    const gpa = std.testing.allocator;
    const tmp = try support.TempDir.create("/tmp/zigder-tags-wide");
    defer tmp.cleanup();
    const root = tmp.path();

    var undo: fs_undo.UndoStack = .{};
    defer undo.deinit(gpa);

    const count = 300;
    const tagged = [_]usize{ 0, 74, 75, 149, 150, 224, 225, 299 };
    for (0..count) |i| {
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "f{d:0>3}.txt", .{i});
        const full = try undo.createFile(gpa, root, name);
        defer gpa.free(full);
        if (std.mem.indexOfScalar(usize, &tagged, i)) |k| {
            try std.testing.expect(volumes.writeTagMask(full, @as(u8, 1) << @intCast(k % 7)));
        }
    }

    var listing = try fs_entry.loadFolder(gpa, root, null, .name, true, true, false);
    defer listing.deinit(gpa);
    try std.testing.expectEqual(@as(usize, count), listing.order.items.len);
    for (listing.order.items, 0..) |eid, i| {
        const want: u8 = if (std.mem.indexOfScalar(usize, &tagged, i)) |k| @as(u8, 1) << @intCast(k % 7) else 0;
        try std.testing.expectEqual(want, listing.entries.items[eid].tag_mask);
    }
}

test "live_sync APFS firmlink canonicalization, fast dead-bit totals, and scoped UI wakes" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqualStrings("/Users/test/devv", live_sync.canonicalEventPath("/System/Volumes/Data/Users/test/devv/").?);
    try std.testing.expectEqualStrings("/", live_sync.canonicalEventPath("/System/Volumes/Data").?);
    try std.testing.expect(live_sync.canonicalEventPath("/System/Volumes/VM/swapfile0") == null);
    try std.testing.expect(live_sync.canonicalEventPath("/Volumes/Ext/file") == null);
    try std.testing.expect(live_sync.canonicalEventPath("/dev/null") == null);

    const tmp = try support.TempDir.create("/tmp/zigder-sync");
    defer tmp.cleanup();
    const root = tmp.path();

    try support.sh(
        "mkdir -p '{s}/dir_a' '{s}/dir_b' && printf '12345' > '{s}/dir_a/keep.txt' && printf '6789' > '{s}/dir_a/drop.txt' && printf 'ab' > '{s}/dir_b/b.txt'",
        .{ root, root, root, root, root },
    );

    var idx_buf: [128]u8 = undefined;
    const idx_path = try std.fmt.bufPrint(&idx_buf, "{s}/sync.zidx", .{root});
    try support.buildRootedIndex(gpa, root, idx_path, 10);

    var eng = try engine_mod.Engine.initHeadlessWithIndex(gpa, idx_path);
    defer eng.deinit();

    var dir_a_buf: [128]u8 = undefined;
    const dir_a = try std.fmt.bufPrint(&dir_a_buf, "{s}/dir_a", .{root});
    var dir_b_buf: [128]u8 = undefined;
    const dir_b = try std.fmt.bufPrint(&dir_b_buf, "{s}/dir_b", .{root});
    var sys_dir_b_buf: [160]u8 = undefined;
    const sys_dir_b = try std.fmt.bufPrint(&sys_dir_b_buf, "/System/Volumes/Data{s}", .{dir_b});

    eng.setUiWatch(dir_a, false);
    const wakes_before = eng.ui_wakes.load(.acquire);

    try support.sh("printf 'added_bytes' > '{s}/new_in_b.txt' && rm -f '{s}/drop.txt'", .{ dir_b, dir_a });

    eng.processEventsBatch(&.{
        .{ .path = sys_dir_b, .flags = 0, .id = 11 },
    }, &.{});
    try std.testing.expectEqual(wakes_before, eng.ui_wakes.load(.acquire));

    const tot_b = eng.totals(dir_b) orelse return error.TotalsMissing;
    try std.testing.expectEqual(@as(u64, 13), tot_b.bytes);
    try std.testing.expectEqual(@as(u64, 2), tot_b.items);

    var ft = (try eng.folderTotals(gpa, root)) orelse return error.FolderTotalsMissing;
    defer ft.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), ft.items.len);
    const dir_b_tot = ft.find("dir_b") orelse return error.FolderTotalsMissing;
    try std.testing.expectEqual(@as(u64, 13), dir_b_tot.bytes);
    try std.testing.expectEqual(@as(u64, 2), dir_b_tot.items);

    eng.processEventsBatch(&.{
        .{ .path = dir_a, .flags = 0, .id = 12 },
    }, &.{});
    try std.testing.expectEqual(wakes_before + 1, eng.ui_wakes.load(.acquire));

    const tot_a = eng.totals(dir_a) orelse return error.TotalsMissing;
    try std.testing.expectEqual(@as(u64, 5), tot_a.bytes);
    try std.testing.expectEqual(@as(u64, 1), tot_a.items);
}

test {
    _ = @import("tests/ui.zig");
    _ = @import("tests/state.zig");
    _ = @import("tests/search.zig");
    _ = @import("tests/commands.zig");
    _ = @import("tests/engine.zig");
    _ = @import("tests/app.zig");
    _ = @import("tests/fileops.zig");
    _ = @import("tests/media.zig");
}
