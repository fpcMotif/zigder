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
