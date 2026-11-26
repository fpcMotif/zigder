const std = @import("std");
const walk = @import("../index/walk.zig");
const index_read = @import("../index/read.zig");
const index_build = @import("../index/build.zig");
const query_mod = @import("../search/query.zig");
const live_mod = @import("../index/live.zig");
const search_mod = @import("../search/search.zig");
const baseline = @import("../search/baseline.zig");
const support = @import("support.zig");

pub fn bruteForceSearch(
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
            try items.append(gpa, baseline.packKey(tot, e));
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
    const nm_id: u32 = @intCast(1 + 2 * BIG_PACKS);
    const dot_id: u32 = nm_id + 1;
    try listings.append(gpa, .{ .id = nm_id });
    try listings.append(gpa, .{ .id = dot_id });
    var nb: [128]u8 = undefined;
    for (0..BIG_PACKS) |p| {
        const pack_name = try std.fmt.bufPrint(&nb, "pack_{d:0>3}", .{p});
        try addEnt(gpa, &listings.items[0], pack_name, walk.KIND_DIR, 0, @intCast(1 + p));
        const pack = &listings.items[1 + p];
        try addEnt(gpa, pack, "src", walk.KIND_DIR, 0, @intCast(1 + BIG_PACKS + p));
        for (0..BIG_FILES) |j| {
            const name = switch (j % 10) {
                0 => try std.fmt.bufPrint(&nb, "e{d}", .{j}),
                1 => try std.fmt.bufPrint(&nb, "e{d}.txt", .{j}),
                2 => try std.fmt.bufPrint(&nb, "beta_{d}.md", .{j}),
                3 => try std.fmt.bufPrint(&nb, "The_File_{d}.zig", .{j}),
                4 => try std.fmt.bufPrint(&nb, "x{d}e", .{j}),
                5 => try std.fmt.bufPrint(&nb, ".env_{d}", .{j}),
                6 => try std.fmt.bufPrint(&nb, "report {d}.pdf", .{j}),
                7 => try std.fmt.bufPrint(&nb, "icon_{d}.json", .{j}),
                8 => try std.fmt.bufPrint(&nb, "con_{d}.json", .{j}),
                else => try std.fmt.bufPrint(&nb, "test_spec_{d}.ts", .{j}),
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
    try addEnt(gpa, &listings.items[1], "node_modules", walk.KIND_DIR, 0, nm_id);
    try addEnt(gpa, &listings.items[nm_id], ".dot", walk.KIND_DIR, 0, dot_id);
    const dot_dir = &listings.items[dot_id];
    for (0..250) |j| {
        const name = try std.fmt.bufPrint(
            &nb,
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbqzx{d:0>3}.log",
            .{j},
        );
        try addEnt(gpa, dot_dir, name, walk.KIND_FILE, 100 + j, walk.NONE);
    }
    for (0..30) |j| {
        const name = try std.fmt.bufPrint(&nb, "bqbbzbbx_{d:0>2}.log", .{j});
        try addEnt(gpa, dot_dir, name, walk.KIND_FILE, 50 + j, walk.NONE);
    }
    for (0..20) |j| {
        const name = try std.fmt.bufPrint(&nb, "qzx_{d:0>2}.log", .{j});
        try addEnt(gpa, &listings.items[1], name, walk.KIND_FILE, 20 + j, walk.NONE);
    }
    return listings;
}

test "searcher matches brute-force oracle on an index above the selective threshold" {
    const gpa = std.testing.allocator;
    const tmp = try support.TempDir.create("/tmp/zigder-big");
    defer tmp.cleanup();
    const root = tmp.path();

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
        "mai",
        "main",
        "rep",
        "bet",
        "in:/pack_007 mai",
        "mai kind:file",
        "qzx",
        "con",
        "ext:json",
        "!pack_003 ext:json",
        "in:/pack_007 ext:json",
        "in:/pack_007 !beta",
        "test spec ts",
        "pack test spec",
        "in:/pack_007 test spec ts",
    };
    const now = query_mod.nowSecs();
    var searcher = search_mod.Searcher.init(gpa);
    defer searcher.deinit();
    var bad: usize = 0;
    for (queries) |qs| {
        for ([_]usize{ 15, 200 }) |limit| {
            var q = try query_mod.Query.parse(gpa, qs, "/nohome");
            defer q.deinit(gpa);
            q.limit = limit;
            try searcher.search(gpa, &live, &q, &res);
            var oracle = try bruteForceSearch(gpa, &live, &q, now);
            defer oracle.deinit(gpa);
            var same = oracle.items.len == res.hits.items.len;
            if (same) {
                for (oracle.items, res.hits.items) |ok, got| {
                    const o_idx = baseline.unpackIdx(ok);
                    const o_sc = baseline.unpackScore(ok);
                    if (o_idx != got.idx or o_sc != got.score) {
                        same = false;
                        break;
                    }
                }
            }
            if (!same) {
                bad += 1;
                std.debug.print("oracle mismatch: query=\"{s}\" limit={d} tier={d} oracle_len={d} got_len={d}\n", .{ qs, limit, res.tier_used, oracle.items.len, res.hits.items.len });
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), bad);
}
