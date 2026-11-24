const std = @import("std");
const fmt = @import("index_fmt.zig");
const index_read = @import("index_read.zig");
const walk = @import("walk.zig");
const fuzzy = @import("fuzzy_simd.zig");
const query_mod = @import("query.zig");
const live_mod = @import("live.zig");
const baseline = @import("search_baseline.zig");
const search_nfa = @import("search_nfa.zig");

pub const TopEntry = struct {
    key: u64,
    overlay_slot: u32,
};

pub const TopK = struct {
    k: usize,
    items: std.ArrayList(TopEntry) = .empty,
    floor: u64 = 0,
    floor_score: i32 = std.math.minInt(i32),
    full: bool = false,

    pub fn deinit(t: *TopK, gpa: std.mem.Allocator) void {
        t.items.deinit(gpa);
    }

    pub inline fn push(t: *TopK, gpa: std.mem.Allocator, score: i32, idx: u32, overlay_slot: u32) !void {
        const key = packKey(score, idx);
        if (t.full and key <= t.floor) return;
        try t.items.append(gpa, .{ .key = key, .overlay_slot = overlay_slot });
        if (t.items.items.len >= @max(t.k * 2, 64)) t.compact();
    }

    pub fn compact(t: *TopK) void {
        if (t.items.items.len <= t.k) {
            if (t.items.items.len == t.k and t.k > 0) {
                std.mem.sort(TopEntry, t.items.items, {}, topDesc);
                t.floor = t.items.items[t.k - 1].key;
                t.floor_score = unpackScore(t.floor);
                t.full = true;
            }
            return;
        }
        std.mem.sort(TopEntry, t.items.items, {}, topDesc);
        t.items.shrinkRetainingCapacity(t.k);
        t.floor = t.items.items[t.k - 1].key;
        t.floor_score = unpackScore(t.floor);
        t.full = true;
    }

    pub fn finish(t: *TopK) []TopEntry {
        std.mem.sort(TopEntry, t.items.items, {}, topDesc);
        const take = @min(t.items.items.len, t.k);
        t.items.shrinkRetainingCapacity(take);
        if (take == t.k and t.k > 0) {
            t.floor = t.items.items[take - 1].key;
            t.floor_score = unpackScore(t.floor);
            t.full = true;
        }
        return t.items.items;
    }

    fn topDesc(_: void, a: TopEntry, b: TopEntry) bool {
        return a.key > b.key;
    }
};

pub inline fn packKey(score: i32, idx: u32) u64 {
    const sc: u64 = @intCast(@as(i64, score) - @as(i64, std.math.minInt(i32)));
    return (sc << 32) | (~idx);
}

pub inline fn unpackScore(k: u64) i32 {
    return @intCast(@as(i64, @intCast(k >> 32)) + @as(i64, std.math.minInt(i32)));
}

pub inline fn unpackIdx(k: u64) u32 {
    return ~@as(u32, @truncate(k));
}

pub const NameScore = struct {
    score: i16,
    is_dot: bool,
    is_app: bool,
};

pub fn dirHasNeg(
    gpa: std.mem.Allocator,
    idx: *const index_read.Index,
    d: u32,
    neg: []const *const fuzzy.Token,
    cache: *std.AutoHashMapUnmanaged(u32, bool),
) !bool {
    if (d == 0 or neg.len == 0) return false;
    if (cache.get(d)) |cached| return cached;
    const de = idx.dirEntry();
    const dp = idx.dirParent();
    const en = idx.entName();
    var chain: [256]u32 = undefined;
    var depth: usize = 0;
    var cur = d;
    var out = false;
    while (cur != 0 and depth < chain.len) {
        if (cache.get(cur)) |cached| {
            out = cached;
            break;
        }
        chain[depth] = cur;
        depth += 1;
        cur = dp[cur];
    }
    var i = depth;
    while (i > 0) {
        i -= 1;
        const dk = chain[i];
        if (!out) {
            const nm = idx.uname(en[de[dk]]);
            for (neg) |nt| {
                if (fuzzy.tokenMatches(nm, nt)) {
                    out = true;
                    break;
                }
            }
        }
        try cache.put(gpa, dk, out);
    }
    return out;
}

pub fn emitSingleEntries(
    gpa: std.mem.Allocator,
    live: *const live_mod.Live,
    q: *const query_mod.Query,
    lo: usize,
    hi: usize,
    now: u32,
    kid: u32,
    ns: NameScore,
    neg: []const *const fuzzy.Token,
    neg_cache: *std.AutoHashMapUnmanaged(u32, bool),
    top: *TopK,
) !void {
    const idx = &live.base;
    const ne_off = idx.nameEntsOff();
    const ne = idx.nameEnts();
    const par_arr = idx.parent();
    const dprior = idx.dirPrior();
    const max_tweak: i32 = 10 + @as(i32, if (ns.is_app) 25 else 0) - @as(i32, if (ns.is_dot) 8 else 0);
    const has_size_filter = q.size_min != 0 or q.size_max != std.math.maxInt(u64);
    const has_mtime_filter = q.mtime_min != 0 or q.mtime_max != std.math.maxInt(u32);

    for (ne[ne_off[kid]..ne_off[kid + 1]]) |e| {
        const dp = dprior[par_arr[e]];
        if (top.full and @as(i32, ns.score) + dp + max_tweak < top.floor_score) break;
        if (e < lo or e >= hi or live.isDead(e)) continue;
        const kv = live.kindOf(e);
        if (!q.kindOk(kv)) continue;
        if (has_size_filter) {
            const sz = idx.sizeOf(e);
            if (sz < q.size_min or sz > q.size_max) continue;
        }
        const mt = live.mtimeOf(e);
        if (has_mtime_filter and (mt < q.mtime_min or mt > q.mtime_max)) continue;
        if (neg.len > 0 and try dirHasNeg(gpa, idx, par_arr[e], neg, neg_cache)) continue;
        const tot = @as(i32, ns.score) + dp + baseline.rankTweaks(ns.is_dot, ns.is_app, kv, mt, now);
        try top.push(gpa, tot, e, walk.NONE);
    }
}

fn computeSeedFloor(
    gpa: std.mem.Allocator,
    live: *const live_mod.Live,
    q: *const query_mod.Query,
    tok: *const fuzzy.Token,
    neg: []const *const fuzzy.Token,
    allow_ext: *const [4]u64,
    lo: usize,
    hi: usize,
    now: u32,
    neg_cache: *std.AutoHashMapUnmanaged(u32, bool),
) !i32 {
    if (tok.mode != .fuzzy or tok.text.len == 0 or q.limit == 0 or q.limit > 256) return std.math.minInt(i32);
    const idx = &live.base;
    const slice = idx.headSlice(fmt.charClass(tok.text[0]));
    if (slice.len == 0) return std.math.minInt(i32);
    const info = idx.nameInfo();
    const name_ext = idx.nameExt();
    const noff = idx.nameOff();
    const names_ptr = idx.names().ptr;
    const ne_off = idx.nameEntsOff();
    const ne = idx.nameEnts();
    const par_arr = idx.parent();
    const dprior = idx.dirPrior();
    const max_tok = fuzzy.maxCleanTokenBound(tok, 0);
    const has_exts = q.exts.items.len > 0;
    const has_size_filter = q.size_min != 0 or q.size_max != std.math.maxInt(u64);
    const has_mtime_filter = q.mtime_min != 0 or q.mtime_max != std.math.maxInt(u32);

    var buf: [256]i32 = undefined;
    var count: usize = 0;
    var floor: i32 = std.math.minInt(i32);
    var min_idx: usize = 0;

    const scan_lim = @min(slice.len, 256);
    const has_c1 = tok.text.len >= 2 and tok.start == 0;
    const bm1_0 = if (has_c1) idx.bitmap(fmt.BM_FIRST + fmt.charClass(tok.text[1])) else &[_]u64{};
    const bm1_1 = if (has_c1) idx.bitmap(fmt.BM_SECOND + fmt.charClass(tok.text[1])) else &[_]u64{};
    for (slice[0..scan_lim]) |kid| {
        const ni = info[kid];
        if (count == q.limit and ni.key > std.math.minInt(i8) and max_tok + @as(i32, ni.key) < floor) break;
        if (has_c1 and ((bm1_0[kid >> 6] | bm1_1[kid >> 6]) & (@as(u64, 1) << @intCast(kid & 63))) == 0) continue;
        const nm = idx.uname(kid);
        if (has_exts) {
            const s = name_ext[kid];
            if (((allow_ext[s / 64] >> @intCast(s % 64)) & 1) == 0) continue;
            if (s == 255 and !query_mod.Query.extOk(nm, q.exts.items)) continue;
        }
        const m = fmt.nameMask(nm);
        if (!tok.fits(m)) continue;
        const wide: ?*const [64]u8 = if (nm.len <= 64) @ptrCast(names_ptr + noff[kid]) else null;
        const sc = fuzzy.tokenScore(nm, wide, m, tok) orelse continue;
        var neg_hit = false;
        for (neg) |nt| {
            if (fuzzy.tokenMatches(nm, nt)) {
                neg_hit = true;
                break;
            }
        }
        if (neg_hit) continue;
        const sc16: i16 = @intCast(std.math.clamp(sc, std.math.minInt(i16), std.math.maxInt(i16)));
        const is_dot = nm.len > 0 and nm[0] == '.';
        const is_app = std.mem.endsWith(u8, nm, ".app");
        const max_tweak: i32 = 10 + @as(i32, if (is_app) 25 else 0) - @as(i32, if (is_dot) 8 else 0);
        for (ne[ne_off[kid]..ne_off[kid + 1]]) |e| {
            const dp = dprior[par_arr[e]];
            if (count == q.limit and @as(i32, sc16) + dp + max_tweak < floor) break;
            if (e < lo or e >= hi or live.isDead(e)) continue;
            const kv = live.kindOf(e);
            if (!q.kindOk(kv)) continue;
            if (has_size_filter) {
                const sz = idx.sizeOf(e);
                if (sz < q.size_min or sz > q.size_max) continue;
            }
            const mt = live.mtimeOf(e);
            if (has_mtime_filter and (mt < q.mtime_min or mt > q.mtime_max)) continue;
            if (neg.len > 0 and try dirHasNeg(gpa, idx, par_arr[e], neg, neg_cache)) continue;
            const tot = @as(i32, sc16) + dp + baseline.rankTweaks(is_dot, is_app, kv, mt, now);
            if (count < q.limit) {
                buf[count] = tot;
                if (count == 0 or tot < floor) {
                    floor = tot;
                    min_idx = count;
                }
                count += 1;
            } else if (tot > floor) {
                buf[min_idx] = tot;
                var new_min = buf[0];
                var new_idx: usize = 0;
                for (buf[1..q.limit], 1..) |v, vi| {
                    if (v < new_min) {
                        new_min = v;
                        new_idx = vi;
                    }
                }
                floor = new_min;
                min_idx = new_idx;
            }
        }
    }
    return if (count == q.limit) floor else std.math.minInt(i32);
}

pub fn runBitmapTier(
    gpa: std.mem.Allocator,
    live: *const live_mod.Live,
    q: *const query_mod.Query,
    pos: []const *const fuzzy.Token,
    neg: []const *const fuzzy.Token,
    allow_ext: *const [4]u64,
    lo: usize,
    hi: usize,
    now: u32,
    neg_cache: *std.AutoHashMapUnmanaged(u32, bool),
    top: *TopK,
    out_cache_ids: ?*std.ArrayList(u32),
) !void {
    const idx = &live.base;
    if (pos.len == 0 and neg.len == 0 and q.exts.items.len == 0) {
        try scanEntriesDirect(gpa, live, q, lo, hi, now, null, top);
        return;
    }

    var plans: [8]search_nfa.TokPlan = undefined;
    for (pos, 0..) |tok, ti| {
        plans[ti] = search_nfa.buildTokPlan(idx, tok);
    }

    const seed_floor = if (pos.len == 1 and out_cache_ids == null)
        try computeSeedFloor(gpa, live, q, pos[0], neg, allow_ext, lo, hi, now, neg_cache)
    else
        std.math.minInt(i32);

    var matched_names: std.ArrayList(search_nfa.NameHitEntry) = .empty;
    defer matched_names.deinit(gpa);
    const ok_entries = try live.pool.runScan(gpa, idx, q, pos, neg, allow_ext, plans[0..pos.len], seed_floor, &matched_names);

    if (out_cache_ids) |cids| {
        if (pos.len == 1 and neg.len == 0 and seed_floor == std.math.minInt(i32) and matched_names.items.len <= 16_384) {
            try cids.ensureTotalCapacity(gpa, matched_names.items.len);
            for (matched_names.items) |m| cids.appendAssumeCapacity(m.id);
        }
    }

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

    const name_lookup = try gpa.alloc(i32, idx.u);
    defer gpa.free(name_lookup);
    @memset(name_lookup, std.math.minInt(i32));
    for (matched_names.items, 0..) |m, mi| name_lookup[m.id] = @intCast(mi);

    if (pos.len <= 1 and neg.len == 0) {
        try scanEntriesDirect(gpa, live, q, lo, hi, now, name_lookup, top);
        return;
    }

    const ne_off = idx.nameEntsOff();
    const ne = idx.nameEnts();
    const par_arr = idx.parent();
    const dprior = idx.dirPrior();
    var pbuf: [2048]u8 = undefined;

    if (ok_entries <= 60_000) {
        for (matched_names.items) |m| {
            for (ne[ne_off[m.id]..ne_off[m.id + 1]]) |e| {
                if (e < lo or e >= hi or live.isDead(e)) continue;
                const kv = live.kindOf(e);
                if (!q.kindOk(kv)) continue;
                const sz = idx.sizeOf(e);
                if (sz < q.size_min or sz > q.size_max) continue;
                const mt = live.mtimeOf(e);
                if (mt < q.mtime_min or mt > q.mtime_max) continue;
                const fp = idx.pathBuf(e, &pbuf) orelse continue;
                if (q.matchPath(fp, kv, sz, mt)) |sc| {
                    const tot = sc + dprior[par_arr[e]] + baseline.rankTweaks(m.is_dot, m.is_app, kv, mt, now);
                    try top.push(gpa, tot, e, walk.NONE);
                }
            }
        }
        return;
    }

    const zones_arr = idx.zones();
    const en_arr = idx.entName();
    var a = lo;
    while (a < hi) {
        const end = @min(((a / fmt.ZONE) + 1) * fmt.ZONE, hi);
        if (!zoneOk(&zones_arr[a / fmt.ZONE], q)) {
            a = end;
            continue;
        }
        for (a..end) |ei| {
            const e: u32 = @intCast(ei);
            const mi = name_lookup[en_arr[e]];
            if (mi < 0 or live.isDead(e)) continue;
            const m = matched_names.items[@intCast(mi)];
            const kv = live.kindOf(e);
            if (!q.kindOk(kv)) continue;
            const sz = idx.sizeOf(e);
            if (sz < q.size_min or sz > q.size_max) continue;
            const mt = live.mtimeOf(e);
            if (mt < q.mtime_min or mt > q.mtime_max) continue;
            const fp = idx.pathBuf(e, &pbuf) orelse continue;
            if (q.matchPath(fp, kv, sz, mt)) |sc| {
                const tot = sc + dprior[par_arr[e]] + baseline.rankTweaks(m.is_dot, m.is_app, kv, mt, now);
                try top.push(gpa, tot, e, walk.NONE);
            }
        }
        a = end;
    }
}

inline fn zoneOk(z: *const fmt.Zone, q: *const query_mod.Query) bool {
    if (z.max_size < q.size_min or z.max_mtime < q.mtime_min or z.min_mtime > q.mtime_max) return false;
    if (q.kind) |want| {
        const kbit = @as(u32, 1) << @intCast(want);
        const lbit = @as(u32, 1) << @intCast(walk.KIND_LINK);
        if ((z.kinds & kbit) == 0 and !(q.apps and (z.kinds & lbit) != 0)) return false;
    }
    return true;
}

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
    const idx = &live.base;
    const zones_arr = idx.zones();
    const en = idx.entName();
    const dprior = idx.dirPrior();
    const par = idx.parent();
    const bm_dot = idx.bitmap(fmt.BM_DOT);
    const bm_app = idx.bitmap(fmt.BM_APP);
    const has_size_filter = q.size_min != 0 or q.size_max != std.math.maxInt(u64);
    const has_mtime_filter = q.mtime_min != 0 or q.mtime_max != std.math.maxInt(u32);

    var a = lo;
    while (a < hi) {
        const end = @min(((a / fmt.ZONE) + 1) * fmt.ZONE, hi);
        if (!zoneOk(&zones_arr[a / fmt.ZONE], q)) {
            a = end;
            continue;
        }
        for (a..end) |ei| {
            const e: u32 = @intCast(ei);
            const kid = en[e];
            if (name_lookup) |nl| {
                if (nl[kid] < 0) continue;
            }
            if (live.isDead(e)) continue;
            const kv = live.kindOf(e);
            if (!q.kindOk(kv)) continue;
            if (has_size_filter) {
                const sz = idx.sizeOf(e);
                if (sz < q.size_min or sz > q.size_max) continue;
            }
            const mt = live.mtimeOf(e);
            if (has_mtime_filter and (mt < q.mtime_min or mt > q.mtime_max)) continue;
            const w = kid >> 6;
            const bit = @as(u64, 1) << @intCast(kid & 63);
            const is_dot = (bm_dot[w] & bit) != 0;
            const is_app = (bm_app[w] & bit) != 0;
            const tot = @as(i32, dprior[par[e]]) + baseline.rankTweaks(is_dot, is_app, kv, mt, now);
            try top.push(gpa, tot, e, walk.NONE);
        }
        a = end;
    }
}
