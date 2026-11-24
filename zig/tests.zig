const std = @import("std");
const nanoui = @import("nanoui");
const measure = @import("measure.zig");
const walk = @import("walk.zig");
const fmt = @import("index_fmt.zig");
const index_read = @import("index_read.zig");
const index_build = @import("index_build.zig");
const fuzzy = @import("fuzzy_simd.zig");
const query_mod = @import("query.zig");
const live_mod = @import("live.zig");
const live_sync = @import("live_sync.zig");
const engine_mod = @import("engine.zig");
const search_mod = @import("search.zig");
const baseline = @import("search_baseline.zig");
const fsevents = @import("fsevents.zig");
const fs_entry = @import("fs_entry.zig");
const fs_ops = @import("fs_ops.zig");
const volumes = @import("volumes.zig");
const quicklook = @import("quicklook.zig");

extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
extern "c" fn system(cmd: [*:0]const u8) c_int;

test "walk scan and buildFromListings roundtrip into ZSIDX001" {
    const gpa = std.testing.allocator;
    var tmp: [64:0]u8 = @splat(0);
    const tmpl = "/tmp/zigder-test-XXXXXX";
    @memcpy(tmp[0..tmpl.len], tmpl);
    _ = mkdtemp(&tmp) orelse return error.TmpDir;
    const root = tmp[0..tmpl.len :0];
    defer {
        var cmd: [128]u8 = undefined;
        const s = std.fmt.bufPrintSentinel(&cmd, "rm -rf '{s}'", .{root}, 0) catch unreachable;
        _ = system(s);
    }

    var cmd_buf: [512]u8 = undefined;
    const setup = try std.fmt.bufPrintSentinel(
        &cmd_buf,
        "mkdir -p '{s}/alpha/nested' '{s}/beta' && printf 'hello world' > '{s}/alpha/readme.md' && printf 'fn main() void {{}}' > '{s}/alpha/nested/main.zig' && printf 'data' > '{s}/beta/Cargo.toml'",
        .{ root, root, root, root, root },
        0,
    );
    try std.testing.expectEqual(@as(c_int, 0), system(setup));

    var scanned = try walk.scan(gpa, root, &.{}, 2);
    defer scanned.deinit();
    try std.testing.expect(scanned.listings.items.len >= 4);

    var idx_path_buf: [128]u8 = undefined;
    const idx_path = try std.fmt.bufPrint(&idx_path_buf, "{s}/test.zidx", .{root});
    try index_build.buildFromListings(scanned.listings.items, 42, 1700000000, root, idx_path);

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
    _ = nanoui.ui;
}

test "simd64Matches lane bit ordering matches scalar across all 64 positions" {
    var buf: [64]u8 = @splat('x');
    for (0..64) |pos| {
        buf[pos] = if ((pos & 1) == 0) 'a' else 'A';
        const m = fuzzy.simd64Matches(&buf, 64, 'a');
        var expected: u64 = 0;
        for (0..64) |j| {
            if (fmt.fold(buf[j]) == 'a') expected |= @as(u64, 1) << @intCast(j);
        }
        try std.testing.expectEqual(expected, m);
        buf[pos] = 'x';
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

test "searcher matches brute-force oracle and Live overlay updates" {
    const gpa = std.testing.allocator;
    var tmp: [64:0]u8 = @splat(0);
    const tmpl = "/tmp/zigder-oracle-XXXXXX";
    @memcpy(tmp[0..tmpl.len], tmpl);
    _ = mkdtemp(&tmp) orelse return error.TmpDir;
    const root = tmp[0..tmpl.len :0];
    defer {
        var cmd: [128]u8 = undefined;
        const s = std.fmt.bufPrintSentinel(&cmd, "rm -rf '{s}'", .{root}, 0) catch unreachable;
        _ = system(s);
    }

    var cmd_buf: [2048]u8 = undefined;
    const setup = try std.fmt.bufPrintSentinel(
        &cmd_buf,
        "mkdir -p '{s}/src/ui' '{s}/apps/Safari.app' '{s}/docs' '{s}/node_modules/pkg' && " ++
            "for i in $(seq 1 60); do printf 'x' > '{s}/src/file_'$i'.zig'; done && " ++
            "printf 'main' > '{s}/src/main.zig' && " ++
            "printf 'readme' > '{s}/docs/README.md' && " ++
            "printf 'cfg' > '{s}/src/ui/config.json' && " ++
            "printf 'fdr' > '{s}/src/finder-fs.rs' && " ++
            "printf 'dot' > '{s}/.gitignore' && " ++
            "printf 'big' > '{s}/docs/archive_data.bin'",
        .{ root, root, root, root, root, root, root, root, root, root, root },
        0,
    );
    try std.testing.expectEqual(@as(c_int, 0), system(setup));

    var scanned = try walk.scan(gpa, root, &.{}, 2);
    defer scanned.deinit();
    var idx_path_buf: [128]u8 = undefined;
    const idx_path = try std.fmt.bufPrint(&idx_path_buf, "{s}/oracle.zidx", .{root});
    try index_build.buildFromListings(scanned.listings.items, 100, 1700000000, root, idx_path);

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
    for (queries) |qs| {
        var q = try query_mod.Query.parse(gpa, qs, root);
        defer q.deinit(gpa);
        q.limit = 15;
        try search_mod.search(gpa, &live, &q, &res);
        var oracle = try bruteForceSearch(gpa, &live, &q, now);
        defer oracle.deinit(gpa);
        try std.testing.expectEqual(oracle.items.len, res.hits.items.len);
        for (oracle.items, res.hits.items) |ok, got| {
            const o_idx = ~@as(u32, @truncate(ok));
            const o_sc: i32 = @intCast(@as(i64, @intCast(ok >> 32)) + @as(i64, std.math.minInt(i32)));
            try std.testing.expectEqual(o_idx, got.idx);
            try std.testing.expectEqual(o_sc, got.score);
        }
    }

    try live.putOverlay("/src/fresh_live_file.zig", walk.KIND_FILE, 128, 4096, now);
    live.removePath("/src/main.zig");

    var q2 = try query_mod.Query.parse(gpa, "fresh_live", root);
    defer q2.deinit(gpa);
    try search_mod.search(gpa, &live, &q2, &res);
    try std.testing.expectEqual(@as(usize, 1), res.hits.items.len);
    try std.testing.expectEqualStrings("/src/fresh_live_file.zig", res.pathOf(res.hits.items[0]));

    var q3 = try query_mod.Query.parse(gpa, "'main.zig", root);
    defer q3.deinit(gpa);
    try search_mod.search(gpa, &live, &q3, &res);
    try std.testing.expectEqual(@as(usize, 0), res.hits.items.len);

    _ = fsevents.currentId();
}

test "fs_entry natural sort, loadFolder, fs_ops with undo/redo, tags, and InspectorPreview" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(std.math.Order.lt, fs_entry.naturalCmp("file2.txt", "file10.txt"));
    try std.testing.expectEqual(std.math.Order.lt, fs_entry.naturalCmp("Item 1", "item 20"));

    var tmp: [64:0]u8 = @splat(0);
    const tmpl = "/tmp/zigder-fsops-XXXXXX";
    @memcpy(tmp[0..tmpl.len], tmpl);
    _ = mkdtemp(&tmp) orelse return error.TmpDir;
    const root = tmp[0..tmpl.len :0];
    defer {
        var cmd: [128]u8 = undefined;
        const s = std.fmt.bufPrintSentinel(&cmd, "rm -rf '{s}'", .{root}, 0) catch unreachable;
        _ = system(s);
    }

    var undo: fs_ops.UndoStack = .{};
    defer undo.deinit(gpa);

    const sub = try fs_ops.createFolder(gpa, root, "project");
    defer gpa.free(sub);
    try undo.record(gpa, .create, "dir", sub);

    const file1 = try fs_ops.createFile(gpa, sub, "note.txt");
    defer gpa.free(file1);
    try undo.record(gpa, .create, "file", file1);

    const dup1 = try fs_ops.duplicateItem(gpa, file1);
    defer gpa.free(dup1);
    try std.testing.expect(std.mem.endsWith(u8, dup1, "note copy.txt"));
    try undo.record(gpa, .copy, file1, dup1);

    const renamed = try fs_ops.renameItem(gpa, dup1, "renamed.txt");
    defer gpa.free(renamed);
    try undo.record(gpa, .rename, dup1, renamed);

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

    try std.testing.expect(try undo.undo(gpa));
    try std.testing.expect(try undo.undo(gpa));
    try std.testing.expect(try undo.redo(gpa));

    var ql: quicklook.QuickLook = .{ .gpa = gpa, .headless = true };
    defer ql.deinit();
    ql.toggle(&.{file1});

    const sb = try volumes.discoverSidebar(gpa, root);
    defer volumes.freeSidebar(gpa, sb);
    try std.testing.expect(sb.len >= 7);
}

test "live_sync APFS firmlink canonicalization, fast dead-bit totals, and scoped UI wakes" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqualStrings("/Users/test/devv", live_sync.canonicalEventPath("/System/Volumes/Data/Users/test/devv/").?);
    try std.testing.expectEqualStrings("/", live_sync.canonicalEventPath("/System/Volumes/Data").?);
    try std.testing.expect(live_sync.canonicalEventPath("/System/Volumes/VM/swapfile0") == null);
    try std.testing.expect(live_sync.canonicalEventPath("/Volumes/Ext/file") == null);
    try std.testing.expect(live_sync.canonicalEventPath("/dev/null") == null);

    var tmp: [64:0]u8 = @splat(0);
    const tmpl = "/tmp/zigder-sync-XXXXXX";
    @memcpy(tmp[0..tmpl.len], tmpl);
    _ = mkdtemp(&tmp) orelse return error.TmpDir;
    const root = tmp[0..tmpl.len :0];
    defer {
        var cmd: [128]u8 = undefined;
        const s = std.fmt.bufPrintSentinel(&cmd, "rm -rf '{s}'", .{root}, 0) catch unreachable;
        _ = system(s);
    }

    var cmd_buf: [512]u8 = undefined;
    const setup = try std.fmt.bufPrintSentinel(
        &cmd_buf,
        "mkdir -p '{s}/dir_a' '{s}/dir_b' && printf '12345' > '{s}/dir_a/keep.txt' && printf '6789' > '{s}/dir_a/drop.txt' && printf 'ab' > '{s}/dir_b/b.txt'",
        .{ root, root, root, root, root },
        0,
    );
    try std.testing.expectEqual(@as(c_int, 0), system(setup));

    var scanned = try walk.scan(gpa, root, &.{}, 2);
    defer scanned.deinit();
    var l0: walk.Listing = .{ .id = 0 };
    defer l0.deinit(gpa);
    try l0.names.appendSlice(gpa, "tmp");
    try l0.ents.append(gpa, .{ .name_off = 0, .name_len = 3, .kind = walk.KIND_DIR, .size = 0, .alloc = 0, .mtime = 0, .child = 1 });
    const root_nm = std.fs.path.basename(root);
    var l1: walk.Listing = .{ .id = 1 };
    defer l1.deinit(gpa);
    try l1.names.appendSlice(gpa, root_nm);
    try l1.ents.append(gpa, .{ .name_off = 0, .name_len = @intCast(root_nm.len), .kind = walk.KIND_DIR, .size = 0, .alloc = 0, .mtime = 0, .child = 2 });
    for (scanned.listings.items) |*l| {
        l.id += 2;
        for (l.ents.items) |*r| {
            if (r.child != walk.NONE) r.child += 2;
        }
    }
    var full_listings: std.ArrayList(walk.Listing) = .empty;
    defer full_listings.deinit(gpa);
    try full_listings.append(gpa, l0);
    try full_listings.append(gpa, l1);
    try full_listings.appendSlice(gpa, scanned.listings.items);

    var idx_buf: [128]u8 = undefined;
    const idx_path = try std.fmt.bufPrint(&idx_buf, "{s}/sync.zidx", .{root});
    try index_build.buildFromListings(full_listings.items, 10, 1700000000, root, idx_path);

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

    const mutate_b = try std.fmt.bufPrintSentinel(
        &cmd_buf,
        "printf 'added_bytes' > '{s}/new_in_b.txt' && rm -f '{s}/drop.txt'",
        .{ dir_b, dir_a },
        0,
    );
    try std.testing.expectEqual(@as(c_int, 0), system(mutate_b));

    eng.processEventsBatch(&.{
        .{ .path = sys_dir_b, .flags = 0, .id = 11, .stream = 1 },
    }, &.{});
    try std.testing.expectEqual(wakes_before, eng.ui_wakes.load(.acquire));

    const tot_b = eng.totals(dir_b) orelse return error.TotalsMissing;
    try std.testing.expectEqual(@as(u64, 13), tot_b.bytes);
    try std.testing.expectEqual(@as(u64, 2), tot_b.items);

    const ft = (try eng.live.?.folderTotals(root, gpa)) orelse return error.FolderTotalsMissing;
    defer gpa.free(ft);
    try std.testing.expectEqual(@as(usize, 2), ft.len);
    for (ft) |row| {
        if (std.mem.eql(u8, row.name, "dir_b")) {
            try std.testing.expectEqual(@as(u64, 13), row.totals.bytes);
            try std.testing.expectEqual(@as(u64, 2), row.totals.items);
        }
    }

    eng.processEventsBatch(&.{
        .{ .path = dir_a, .flags = 0, .id = 12, .stream = 1 },
    }, &.{});
    try std.testing.expectEqual(wakes_before + 1, eng.ui_wakes.load(.acquire));

    const tot_a = eng.totals(dir_a) orelse return error.TotalsMissing;
    try std.testing.expectEqual(@as(u64, 5), tot_a.bytes);
    try std.testing.expectEqual(@as(u64, 1), tot_a.items);
}

test {
    _ = @import("tests_ui.zig");
    _ = @import("tests_state.zig");
    _ = @import("tests_search.zig");
}
