const std = @import("std");
const fmt = @import("../index/fmt.zig");
const index_read = @import("../index/read.zig");
const walk = @import("../index/walk.zig");
const fuzzy = @import("fuzzy_simd.zig");
const query_mod = @import("query.zig");
const live_mod = @import("../index/live.zig");
const baseline = @import("baseline.zig");
const search_nfa = @import("nfa.zig");
const bitmap_tier = @import("bitmap.zig");

pub const MEMO_MIN_ENTRIES: usize = 2_048;
const NO_SCORE: i16 = std.math.minInt(i16);

pub const Scratch = struct {
    name_lookup: []i32 = &.{},
    bits: []u8 = &.{},
    best: []i16 = &.{},
    dir_hits: std.ArrayList(u32) = .empty,

    pub fn deinit(s: *Scratch, gpa: std.mem.Allocator) void {
        if (s.name_lookup.len > 0) gpa.free(s.name_lookup);
        if (s.bits.len > 0) gpa.free(s.bits);
        if (s.best.len > 0) gpa.free(s.best);
        s.dir_hits.deinit(gpa);
        s.* = .{};
    }

    pub fn prepareLookup(
        s: *Scratch,
        gpa: std.mem.Allocator,
        u: usize,
        matched: []const search_nfa.NameHitEntry,
    ) ![]i32 {
        if (s.name_lookup.len < u) {
            if (s.name_lookup.len > 0) gpa.free(s.name_lookup);
            s.name_lookup = try gpa.alloc(i32, u);
            @memset(s.name_lookup, -1);
        }
        for (matched, 0..) |m, mi| s.name_lookup[m.id] = @intCast(mi);
        return s.name_lookup;
    }

    pub fn clearLookup(s: *Scratch, matched: []const search_nfa.NameHitEntry) void {
        for (matched) |m| s.name_lookup[m.id] = -1;
    }
};

fn lowerBoundEntry(de: []const u32, target: usize) usize {
    var lo: usize = 0;
    var hi: usize = de.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (de[mid] < target) lo = mid + 1 else hi = mid;
    }
    return lo;
}

inline fn stepDirMemo(
    gpa: std.mem.Allocator,
    idx: *const index_read.Index,
    de: []const u32,
    en: []const u32,
    pos: []const *const fuzzy.Token,
    matched: []const search_nfa.NameHitEntry,
    name_lookup: []const i32,
    multi_cache: *std.AutoHashMapUnmanaged(u32, [8]i16),
    bits: []u8,
    best: []i16,
    npos: usize,
    k: usize,
    p: usize,
) !void {
    bits[k] = bits[p];
    @memcpy(best[k * npos ..][0..npos], best[p * npos ..][0..npos]);
    const mi_signed = name_lookup[en[de[k]]];
    if (mi_signed < 0) return;
    const m = matched[@intCast(mi_signed)];
    if (m.bits == 0) return;
    if ((m.bits & (m.bits - 1)) == 0) {
        const t_only = @ctz(m.bits);
        const own_sc: i16 = @max(m.score, NO_SCORE + 1);
        const slot = &best[k * npos + t_only];
        if (own_sc > slot.*) slot.* = own_sc;
    } else {
        const gop = try multi_cache.getOrPut(gpa, m.id);
        if (!gop.found_existing) {
            var scores: [8]i16 = @splat(NO_SCORE);
            const nm = idx.uname(m.id);
            const mask = fmt.nameMask(nm);
            const wide = idx.unameWide(m.id);
            for (pos, 0..) |tok, t| {
                if (((m.bits >> @intCast(t)) & 1) == 0) continue;
                const sc = fuzzy.tokenScore(nm, wide, mask, tok) orelse continue;
                scores[t] = @intCast(std.math.clamp(sc, NO_SCORE + 1, std.math.maxInt(i16)));
            }
            gop.value_ptr.* = scores;
        }
        for (best[k * npos ..][0..npos], gop.value_ptr.*[0..npos]) |*b, o| b.* = @max(b.*, o);
    }
    bits[k] |= m.bits;
}

inline fn recordDirHit(
    gpa: std.mem.Allocator,
    scratch: *Scratch,
    dir_start: []const u32,
    dir_len: []const u32,
    lo: usize,
    hi: usize,
    k: u32,
    b: u8,
    dir_mask_entries: *[256]usize,
) !void {
    if (b == 0) return;
    const s = @max(@as(usize, dir_start[k]), lo);
    const e_end = @min(@as(usize, dir_start[k] + dir_len[k]), hi);
    if (s >= e_end) return;
    try scratch.dir_hits.append(gpa, k);
    dir_mask_entries[b] += e_end - s;
}

fn buildDirMemo(
    gpa: std.mem.Allocator,
    live: *const live_mod.Live,
    pos: []const *const fuzzy.Token,
    matched: []const search_nfa.NameHitEntry,
    name_lookup: []const i32,
    lo: usize,
    hi: usize,
    scratch: *Scratch,
) ![256]usize {
    var dir_mask_entries: [256]usize = @splat(0);
    const idx = &live.base;
    const npos = pos.len;
    if (scratch.bits.len < idx.d) {
        if (scratch.bits.len > 0) gpa.free(scratch.bits);
        scratch.bits = try gpa.alloc(u8, idx.d);
    }
    if (scratch.best.len < idx.d * npos) {
        if (scratch.best.len > 0) gpa.free(scratch.best);
        scratch.best = try gpa.alloc(i16, idx.d * npos);
    }
    scratch.dir_hits.clearRetainingCapacity();
    if (idx.d == 0) return dir_mask_entries;

    const bits = scratch.bits;
    const best = scratch.best;
    bits[0] = 0;
    @memset(best[0..npos], NO_SCORE);

    var multi_cache: std.AutoHashMapUnmanaged(u32, [8]i16) = .empty;
    defer multi_cache.deinit(gpa);

    const de = idx.dirEntry();
    const dp = idx.dirParent();
    const en = idx.entName();
    const dir_start = idx.dirStart();
    const dir_len = idx.dirLen();

    if (lo > 1 or hi < idx.n) {
        const d_scope = idx.parent()[lo];
        var chain: [256]u32 = undefined;
        var depth: usize = 0;
        var cur = d_scope;
        while (cur != 0 and depth < chain.len) {
            chain[depth] = cur;
            depth += 1;
            cur = dp[cur];
        }
        if (cur == 0) {
            var ci = depth;
            while (ci > 0) {
                ci -= 1;
                const dk: usize = chain[ci];
                try stepDirMemo(gpa, idx, de, en, pos, matched, name_lookup, &multi_cache, bits, best, npos, dk, dp[dk]);
            }
            if (d_scope != 0) {
                try recordDirHit(gpa, scratch, dir_start, dir_len, lo, hi, d_scope, bits[d_scope], &dir_mask_entries);
            }
            const k_lo = @max(@as(usize, 1), lowerBoundEntry(de, lo));
            const k_hi = lowerBoundEntry(de, hi);
            for (k_lo..k_hi) |k| {
                try stepDirMemo(gpa, idx, de, en, pos, matched, name_lookup, &multi_cache, bits, best, npos, k, dp[k]);
                try recordDirHit(gpa, scratch, dir_start, dir_len, lo, hi, @intCast(k), bits[k], &dir_mask_entries);
            }
            return dir_mask_entries;
        }
    }

    for (1..idx.d) |k| {
        const p = dp[k];
        std.debug.assert(p < k);
        try stepDirMemo(gpa, idx, de, en, pos, matched, name_lookup, &multi_cache, bits, best, npos, k, p);
        try recordDirHit(gpa, scratch, dir_start, dir_len, lo, hi, @intCast(k), bits[k], &dir_mask_entries);
    }
    return dir_mask_entries;
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
    scratch: *Scratch,
    top: *bitmap_tier.TopK,
) !void {
    const idx = &live.base;
    const npos = pos.len;
    const state_count = @as(usize, 1) << @intCast(npos);
    const all: u8 = @intCast(state_count - 1);

    const name_lookup = try scratch.prepareLookup(gpa, idx.u, matched);
    defer scratch.clearLookup(matched);

    const dir_mask_entries = try buildDirMemo(gpa, live, pos, matched, name_lookup, lo, hi, scratch);
    const bits = scratch.bits;
    const best = scratch.best;

    const ne_off = idx.nameEntsOff();
    const ne = idx.nameEnts();
    const en = idx.entName();
    const par = idx.parent();
    const dprior = idx.dirPrior();
    const has_size_filter = q.size_min != 0 or q.size_max != std.math.maxInt(u64);
    const has_mtime_filter = q.mtime_min != 0 or q.mtime_max != std.math.maxInt(u32);

    var dir_superset = dir_mask_entries;
    for (0..npos) |bit| {
        const step = @as(usize, 1) << @intCast(bit);
        for (0..state_count) |mask| {
            if ((mask & step) == 0) dir_superset[mask] += dir_superset[mask | step];
        }
    }

    var mask_entries: [256]usize = @splat(0);
    for (matched) |m| {
        mask_entries[m.bits] += ne_off[m.id + 1] - ne_off[m.id];
    }

    var use_dir: [256]bool = @splat(false);
    var dir_trigger: [256]bool = @splat(false);
    var any_dir = false;
    for (1..state_count) |b| {
        if (mask_entries[b] == 0) continue;
        const req = @as(usize, all) & ~b;
        if (req != 0 and dir_superset[req] < mask_entries[b]) {
            use_dir[b] = true;
            any_dir = true;
            for (1..state_count) |db| {
                if ((db & req) == req) dir_trigger[db] = true;
            }
        }
    }

    const Ctx = struct {
        gpa: std.mem.Allocator,
        live: *const live_mod.Live,
        q: *const query_mod.Query,
        neg: []const *const fuzzy.Token,
        neg_cache: *std.AutoHashMapUnmanaged(u32, bool),
        bits: []const u8,
        best: []const i16,
        npos: usize,
        dprior: []const i8,
        all: u8,
        now: u32,
        has_size_filter: bool,
        has_mtime_filter: bool,
        top: *bitmap_tier.TopK,

        inline fn entryAt(c: *const @This(), e: u32, m: search_nfa.NameHitEntry, p: u32) !void {
            if ((m.bits | c.bits[p]) != c.all) return;
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
            if (m.bits != c.all) {
                const p_best = c.best[@as(usize, p) * c.npos ..][0..c.npos];
                for (p_best, 0..) |b, t| {
                    if (((m.bits >> @intCast(t)) & 1) == 0) sc += @divTrunc(@as(i32, b) * 3, 4);
                }
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
        .bits = bits,
        .best = best,
        .npos = npos,
        .dprior = dprior,
        .all = all,
        .now = now,
        .has_size_filter = has_size_filter,
        .has_mtime_filter = has_mtime_filter,
        .top = top,
    };

    for (matched) |m| {
        if (m.bits == 0 or use_dir[m.bits]) continue;
        for (ne[ne_off[m.id]..ne_off[m.id + 1]]) |e| {
            if (e < lo or e >= hi) continue;
            try ctx.entryAt(e, m, par[e]);
        }
    }
    if (!any_dir) return;

    const dir_start = idx.dirStart();
    const dir_len = idx.dirLen();
    const zones_arr = idx.zones();
    const has_zone_filter = q.kind != null or has_size_filter or has_mtime_filter;

    for (scratch.dir_hits.items) |p| {
        const p_bits = bits[p];
        if (!dir_trigger[p_bits]) continue;
        const s = @max(@as(usize, dir_start[p]), lo);
        const e_end = @min(@as(usize, dir_start[p] + dir_len[p]), hi);
        if (s >= e_end) continue;
        if (neg.len > 0 and try bitmap_tier.dirHasNeg(gpa, idx, p, neg, neg_cache)) continue;
        const p_best = best[@as(usize, p) * npos ..][0..npos];
        const p_prior: i32 = dprior[p];
        var a = s;
        while (a < e_end) {
            const z_end = @min(((a / fmt.ZONE) + 1) * fmt.ZONE, e_end);
            if (has_zone_filter and !bitmap_tier.zoneOk(&zones_arr[a / fmt.ZONE], q)) {
                a = z_end;
                continue;
            }
            for (a..z_end) |ei| {
                const mi = name_lookup[en[ei]];
                if (mi < 0) continue;
                const m = matched[@intCast(mi)];
                if (!use_dir[m.bits] or (m.bits | p_bits) != all) continue;
                const e: u32 = @intCast(ei);
                if (live.isDead(e)) continue;
                const kv = live.kindOf(e);
                if (!q.kindOk(kv)) continue;
                if (has_size_filter) {
                    const sz = idx.sizeOf(e);
                    if (sz < q.size_min or sz > q.size_max) continue;
                }
                const mt = live.mtimeOf(e);
                if (has_mtime_filter and (mt < q.mtime_min or mt > q.mtime_max)) continue;
                var sc: i32 = m.score;
                for (p_best, 0..) |b, t| {
                    if (((m.bits >> @intCast(t)) & 1) == 0) sc += @divTrunc(@as(i32, b) * 3, 4);
                }
                const tot = sc + p_prior + baseline.rankTweaks(m.is_dot, m.is_app, kv, mt, now);
                try top.push(gpa, tot, e, walk.NONE);
            }
            a = z_end;
        }
    }
}
