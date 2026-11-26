const std = @import("std");
const fmt = @import("../index/fmt.zig");
const index_read = @import("../index/read.zig");
const walk = @import("../index/walk.zig");
const fuzzy = @import("fuzzy_simd.zig");
const query_mod = @import("query.zig");
const live_mod = @import("../index/live.zig");
const baseline = @import("baseline.zig");
const bitmap_tier = @import("bitmap.zig");
const search_memo = @import("memo.zig");
const search_nfa = @import("nfa.zig");
const measure = @import("../measure.zig");

const TopK = bitmap_tier.TopK;
const NameScore = bitmap_tier.NameScore;

pub const Hit = struct {
    score: i32,
    idx: u32,
    kind: u8,
    size: u64,
    mtime: u32,
    path_off: u32,
    path_len: u16,
};

pub const SearchResults = struct {
    hits: std.ArrayList(Hit) = .empty,
    paths: std.ArrayList(u8) = .empty,
    elapsed_us: u64 = 0,
    tier_used: u8 = 0,

    pub fn deinit(r: *SearchResults, gpa: std.mem.Allocator) void {
        r.hits.deinit(gpa);
        r.paths.deinit(gpa);
    }

    pub fn clear(r: *SearchResults) void {
        r.hits.clearRetainingCapacity();
        r.paths.clearRetainingCapacity();
        r.elapsed_us = 0;
        r.tier_used = 0;
    }

    pub fn pathOf(r: *const SearchResults, h: Hit) []const u8 {
        return r.paths.items[h.path_off..][0..h.path_len];
    }
};

pub fn scopeRange(idx: *const index_read.Index, scope: ?[]const u8) ?[2]usize {
    const s = scope orelse return .{ 1, idx.n };
    if (std.mem.eql(u8, s, "/")) return .{ 1, idx.n };
    const e = idx.lookup(s) orelse return null;
    const d = idx.dirOf(e) orelse return null;
    return .{ idx.dirStart()[d], idx.dirEnd()[d] };
}

pub const Searcher = struct {
    gpa: std.mem.Allocator,
    pool: ?*search_nfa.Pool = null,
    scratch: search_memo.Scratch = .{},

    pub fn init(gpa: std.mem.Allocator) Searcher {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Searcher) void {
        if (self.pool) |p| {
            p.destroy(self.gpa);
            self.pool = null;
        }
        self.scratch.deinit(self.gpa);
    }

    fn ensurePool(self: *Searcher) !*search_nfa.Pool {
        if (self.pool) |p| return p;
        const p = try search_nfa.Pool.create(self.gpa);
        self.pool = p;
        return p;
    }

    pub fn search(
        self: *Searcher,
        gpa: std.mem.Allocator,
        live: *const live_mod.Live,
        q: *const query_mod.Query,
        out: *SearchResults,
    ) !void {
        const t0 = measure.nanos();
        out.clear();
        if (q.limit == 0) return;

        const idx = &live.base;
        const now = query_mod.nowSecs();
        var pos_toks: [8]*const fuzzy.Token = undefined;
        var npos: usize = 0;
        var neg_toks: [16]*const fuzzy.Token = undefined;
        var nneg: usize = 0;
        for (q.tokens.items) |*tok| {
            if (tok.negate) {
                if (nneg < neg_toks.len) {
                    neg_toks[nneg] = tok;
                    nneg += 1;
                }
            } else if (npos < pos_toks.len) {
                pos_toks[npos] = tok;
                npos += 1;
            }
        }

        var top: TopK = .{ .k = q.limit };
        defer top.deinit(gpa);

        if (scopeRange(idx, q.scope)) |range| {
            const lo = range[0];
            const hi = range[1];
            if (lo < hi) {
                out.tier_used = try searchBase(
                    gpa,
                    self,
                    live,
                    q,
                    pos_toks[0..npos],
                    neg_toks[0..nneg],
                    lo,
                    hi,
                    now,
                    &top,
                );
            }
        }

        if (live.overlay_items.items.len > 0) {
            try searchOverlay(gpa, live, q, pos_toks[0..npos], now, &top);
        }

        const sorted = top.finish();
        try out.hits.ensureTotalCapacity(gpa, sorted.len);
        var pbuf: [2048]u8 = undefined;
        for (sorted) |entry| {
            if (entry.overlay_slot == walk.NONE) {
                const e = baseline.unpackIdx(entry.key);
                const path = idx.pathBuf(e, &pbuf) orelse continue;
                const poff: u32 = @intCast(out.paths.items.len);
                try out.paths.appendSlice(gpa, path);
                out.hits.appendAssumeCapacity(.{
                    .score = baseline.unpackScore(entry.key),
                    .idx = e,
                    .kind = live.kindOf(e),
                    .size = idx.sizeOf(e),
                    .mtime = live.mtimeOf(e),
                    .path_off = poff,
                    .path_len = @intCast(path.len),
                });
            } else {
                const ov = live.overlay_items.items[entry.overlay_slot];
                const path = live.overlayPath(ov);
                const poff: u32 = @intCast(out.paths.items.len);
                try out.paths.appendSlice(gpa, path);
                out.hits.appendAssumeCapacity(.{
                    .score = baseline.unpackScore(entry.key),
                    .idx = walk.NONE,
                    .kind = ov.kind,
                    .size = ov.size,
                    .mtime = ov.mtime,
                    .path_off = poff,
                    .path_len = @intCast(path.len),
                });
            }
        }
        out.elapsed_us = (measure.nanos() - t0) / 1000;
    }
};

fn searchBase(
    gpa: std.mem.Allocator,
    searcher: *Searcher,
    live: *const live_mod.Live,
    q: *const query_mod.Query,
    pos: []const *const fuzzy.Token,
    neg: []const *const fuzzy.Token,
    lo: usize,
    hi: usize,
    now: u32,
    top: *TopK,
) !u8 {
    const idx = &live.base;
    var allow_ext: [4]u64 = @splat(0);
    for (q.exts.items) |ex| {
        const s = idx.extSlot(ex);
        allow_ext[s / 64] |= @as(u64, 1) << @intCast(s % 64);
    }

    var neg_dir_cache: std.AutoHashMapUnmanaged(u32, bool) = .empty;
    defer neg_dir_cache.deinit(gpa);

    var floor_hint: i32 = std.math.minInt(i32);
    if (pos.len == 1 and pos[0].text.len >= 3) {
        const tok = pos[0];
        const done = try tryTrigramTier(gpa, live, q, tok, neg, &allow_ext, lo, hi, now, &neg_dir_cache, top);
        if (done) return 1;
        if (top.full) floor_hint = top.floor_score;
        top.items.clearRetainingCapacity();
        top.floor = 0;
        top.floor_score = std.math.minInt(i32);
        top.full = false;
    }

    if (pos.len == 1 and tokCanUseHeadBucket(pos[0])) {
        const tok = pos[0];
        const slice = idx.headSlice(fmt.charClass(tok.text[0]));
        const info = idx.nameInfo();
        const max_tok = fuzzy.maxCleanTokenBound(tok);
        for (slice) |kid| {
            const ni = info[kid];
            if (top.full and ni.key > std.math.minInt(i8) and max_tok + @as(i32, ni.key) < top.floor_score) break;
            if (scoreNameSingle(idx, q, tok, neg, &allow_ext, kid)) |ns| {
                try bitmap_tier.emitSingleEntries(gpa, live, q, lo, hi, now, kid, ns, neg, &neg_dir_cache, top);
            }
        }
        return 2;
    }

    if (hi - lo <= 16_384 and pos.len <= 1 and (pos.len == 1 or neg.len > 0 or q.exts.items.len > 0)) {
        try searchSmallScopeSingle(gpa, live, q, pos, neg, &allow_ext, lo, hi, now, &neg_dir_cache, top);
        return 2;
    }

    const pool = try searcher.ensurePool();
    try bitmap_tier.runBitmapTier(
        gpa,
        live,
        pool,
        &searcher.scratch,
        q,
        pos,
        neg,
        &allow_ext,
        lo,
        hi,
        now,
        &neg_dir_cache,
        top,
        floor_hint,
    );
    return 2;
}

fn searchSmallScopeSingle(
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
) !void {
    const REJECT: i16 = std.math.minInt(i16);
    const idx = &live.base;
    const zones_arr = idx.zones();
    const en = idx.entName();
    const par = idx.parent();
    const dprior = idx.dirPrior();
    const bm_dot = idx.bitmap(fmt.BM_DOT);
    const bm_app = idx.bitmap(fmt.BM_APP);
    const has_size_filter = q.size_min != 0 or q.size_max != std.math.maxInt(u64);
    const has_mtime_filter = q.mtime_min != 0 or q.mtime_max != std.math.maxInt(u32);

    var name_cache: std.AutoHashMapUnmanaged(u32, i16) = .empty;
    defer name_cache.deinit(gpa);

    var a = lo;
    while (a < hi) {
        const end = @min(((a / fmt.ZONE) + 1) * fmt.ZONE, hi);
        if (!bitmap_tier.zoneOk(&zones_arr[a / fmt.ZONE], q)) {
            a = end;
            continue;
        }
        for (a..end) |ei| {
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
            const kid = en[e];
            const gop = try name_cache.getOrPut(gpa, kid);
            if (!gop.found_existing) {
                gop.value_ptr.* = if (pos.len == 1) blk: {
                    const ns = scoreNameSingle(idx, q, pos[0], neg, allow_ext, kid) orelse break :blk REJECT;
                    break :blk @max(ns.score, REJECT + 1);
                } else blk: {
                    const nm = idx.uname(kid);
                    if (q.exts.items.len > 0) {
                        const s = idx.nameExt()[kid];
                        if (((allow_ext[s / 64] >> @intCast(s % 64)) & 1) == 0) break :blk REJECT;
                        if (s == 255 and !query_mod.Query.extOk(nm, q.exts.items)) break :blk REJECT;
                    }
                    for (neg) |nt| {
                        if (fuzzy.tokenMatches(nm, nt)) break :blk REJECT;
                    }
                    break :blk 0;
                };
            }
            const sc = gop.value_ptr.*;
            if (sc == REJECT) continue;
            const p = par[e];
            if (neg.len > 0 and try bitmap_tier.dirHasNeg(gpa, idx, p, neg, neg_cache)) continue;
            const w = kid >> 6;
            const bit = @as(u64, 1) << @intCast(kid & 63);
            const is_dot = (bm_dot[w] & bit) != 0;
            const is_app = (bm_app[w] & bit) != 0;
            const tot = @as(i32, sc) + @as(i32, dprior[p]) + baseline.rankTweaks(is_dot, is_app, kv, mt, now);
            try top.push(gpa, tot, e, walk.NONE);
        }
        a = end;
    }
}

fn tokCanUseHeadBucket(tok: *const fuzzy.Token) bool {
    return tok.mode == .prefix and tok.text.len >= 1 and tok.text[0] != '.';
}

inline fn scoreNameSingle(
    idx: *const index_read.Index,
    q: *const query_mod.Query,
    tok: *const fuzzy.Token,
    neg: []const *const fuzzy.Token,
    allow_ext: *const [4]u64,
    kid: u32,
) ?NameScore {
    const nm = idx.uname(kid);
    if (q.exts.items.len > 0) {
        const s = idx.nameExt()[kid];
        if (((allow_ext[s / 64] >> @intCast(s % 64)) & 1) == 0) return null;
        if (s == 255 and !query_mod.Query.extOk(nm, q.exts.items)) return null;
    }
    const m = fmt.nameMask(nm);
    if (!tok.fits(m)) return null;
    const sc = fuzzy.tokenScore(nm, idx.unameWide(kid), m, tok) orelse return null;
    for (neg) |nt| {
        if (fuzzy.tokenMatches(nm, nt)) return null;
    }
    return .{
        .score = @intCast(std.math.clamp(sc, std.math.minInt(i16), std.math.maxInt(i16))),
        .is_dot = nm.len > 0 and nm[0] == '.',
        .is_app = std.mem.endsWith(u8, nm, ".app"),
    };
}

fn tryTrigramTier(
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
    top: *TopK,
) !bool {
    const idx = &live.base;
    const tlen = tok.text.len;
    var tri_ids: [64]u32 = undefined;
    var ntri: usize = 0;
    const max_i = @min(tlen - 2, tri_ids.len);
    for (0..max_i) |i| {
        const tri = fmt.trigramId(tok.text[i], tok.text[i + 1], tok.text[i + 2]);
        var dup = false;
        for (tri_ids[0..ntri]) |prev| {
            if (prev == tri) {
                dup = true;
                break;
            }
        }
        if (!dup) {
            tri_ids[ntri] = tri;
            ntri += 1;
        }
    }

    var slices_buf: [64][]const u32 = undefined;
    for (0..ntri) |i| {
        slices_buf[i] = idx.trigramSlice(tri_ids[i]);
        if (slices_buf[i].len == 0) {
            return tok.mode != .fuzzy;
        }
    }
    const slices = slices_buf[0..ntri];
    std.mem.sort([]const u32, slices, {}, struct {
        fn lessThan(_: void, a: []const u32, b: []const u32) bool {
            return a.len < b.len;
        }
    }.lessThan);

    const info = idx.nameInfo();
    const max_tok_no_len = fuzzy.maxCleanTokenBound(tok);
    const primary = slices[0];
    const rest = slices[1..];
    var cursors: [63]usize = @splat(0);

    for (primary) |kid| {
        const ni = info[kid];
        if (top.full and ni.key > std.math.minInt(i8) and max_tok_no_len + @as(i32, ni.key) < top.floor_score) {
            break;
        }
        if (top.full and ni.key > std.math.minInt(i8) and search_nfa.cheapNameBound(ni, tok) < top.floor_score) {
            continue;
        }
        var in_all = true;
        for (rest, 0..) |rslice, ri| {
            if (!findInSortedPostings(rslice, &cursors[ri], info, ni.key, kid)) {
                in_all = false;
                break;
            }
        }
        if (!in_all) continue;
        if (scoreNameSingle(idx, q, tok, neg, allow_ext, kid)) |ns| {
            try bitmap_tier.emitSingleEntries(gpa, live, q, lo, hi, now, kid, ns, neg, neg_cache, top);
        }
    }
    top.compact();

    if (tok.mode != .fuzzy) return true;
    if (top.full) {
        const escape = @max(fuzzy.maxBrokenTrigramBound(tok.text), fuzzy.maxTypoBound(tok.text)) + @as(i32, idx.top_prior) + 35;
        if (top.floor_score >= escape) return true;
        if (tlen <= tri_ids.len + 2) {
            const raw_broken_max: i32 = 24 * @as(i32, @intCast(tlen)) + 5;
            var needed_key = top.floor_score - raw_broken_max;
            if (needed_key > idx.by_key_cover and needed_key > std.math.minInt(i8)) {
                for (idx.byKey()) |kid| {
                    const ni = info[kid];
                    if (@as(i32, ni.key) < needed_key) break;
                    if (fuzzy.hasAllTrigrams(idx.uname(kid), tok.text)) continue;
                    if (scoreNameSingle(idx, q, tok, neg, allow_ext, kid)) |ns| {
                        try bitmap_tier.emitSingleEntries(gpa, live, q, lo, hi, now, kid, ns, neg, neg_cache, top);
                        if (top.full) {
                            const nk = top.floor_score - raw_broken_max;
                            if (nk > needed_key) needed_key = nk;
                        }
                    }
                }
                top.compact();
                return true;
            }
        }
    }
    return false;
}

inline fn findInSortedPostings(
    slice: []const u32,
    cursor: *usize,
    info: []const fmt.NameInfo,
    target_key: i8,
    target_id: u32,
) bool {
    var cur = cursor.*;
    if (cur >= slice.len) return false;
    const c_id = slice[cur];
    const c_key = info[c_id].key;
    if (c_key == target_key and c_id == target_id) {
        cursor.* = cur + 1;
        return true;
    }
    if (c_key < target_key or (c_key == target_key and c_id > target_id)) return false;

    var step: usize = 1;
    var prev = cur;
    while (cur < slice.len) {
        const sid = slice[cur];
        const sk = info[sid].key;
        if (sk < target_key or (sk == target_key and sid >= target_id)) break;
        prev = cur;
        cur += step;
        step <<= 1;
    }
    var lo = prev;
    var hi = @min(cur + 1, slice.len);
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const mid_id = slice[mid];
        const mid_key = info[mid_id].key;
        if (mid_key > target_key or (mid_key == target_key and mid_id < target_id)) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    cursor.* = lo;
    if (lo < slice.len and slice[lo] == target_id) {
        cursor.* = lo + 1;
        return true;
    }
    return false;
}

fn searchOverlay(
    gpa: std.mem.Allocator,
    live: *const live_mod.Live,
    q: *const query_mod.Query,
    pos: []const *const fuzzy.Token,
    now: u32,
    top: *TopK,
) !void {
    for (live.overlay_items.items, 0..) |ov, slot| {
        if (!ov.alive) continue;
        if (pos.len > 0) {
            var any_fit = false;
            for (pos) |tok| {
                if (tok.fits(ov.mask)) {
                    any_fit = true;
                    break;
                }
            }
            if (!any_fit) continue;
        }
        const full_p = live.overlayPath(ov);
        if (q.matchPath(full_p, ov.kind, ov.size, ov.mtime)) |sc| {
            const nm = live.overlayName(ov);
            const is_dot = nm.len > 0 and nm[0] == '.';
            const is_app = std.mem.endsWith(u8, nm, ".app");
            const tot = sc + ov.prior + baseline.rankTweaks(is_dot, is_app, ov.kind, ov.mtime, now);
            try top.push(gpa, tot, walk.NONE, @intCast(slot));
        }
    }
}
