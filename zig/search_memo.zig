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
