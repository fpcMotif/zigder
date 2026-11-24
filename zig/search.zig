const std = @import("std");
const fmt = @import("index_fmt.zig");
const index_read = @import("index_read.zig");
const walk = @import("walk.zig");
const fuzzy = @import("fuzzy_simd.zig");
const query_mod = @import("query.zig");
const live_mod = @import("live.zig");
const baseline = @import("search_baseline.zig");
const bitmap_tier = @import("search_bitmap.zig");
const measure = @import("measure.zig");

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

pub const SearchCache = struct {
    epoch: u64 = 0,
    complete: bool = false,
    token_buf: [128]u8 = undefined,
    token_len: usize = 0,
    mode: fuzzy.Mode = .fuzzy,
    takes_typos: bool = false,
    has_scope: bool = false,
    scope_lo: usize = 0,
    scope_hi: usize = 0,
    ext_hash: u64 = 0,
    kind: ?u8 = null,
    apps: bool = false,
    size_min: u64 = 0,
    size_max: u64 = std.math.maxInt(u64),
    mtime_min: u32 = 0,
    mtime_max: u32 = std.math.maxInt(u32),
    neg_hash: u64 = 0,
    name_ids: std.ArrayList(u32) = .empty,

    pub fn deinit(c: *SearchCache, gpa: std.mem.Allocator) void {
        c.name_ids.deinit(gpa);
    }

    pub fn invalidate(c: *SearchCache) void {
        c.complete = false;
        c.name_ids.clearRetainingCapacity();
    }

    fn hashExts(exts: []const []const u8) u64 {
        var h: u64 = exts.len;
        for (exts) |e| h = std.hash.Wyhash.hash(h, e);
        return h;
    }

    fn hashNeg(tokens: []const fuzzy.Token) u64 {
        var h: u64 = 0;
        for (tokens) |t| {
            if (t.negate) h = std.hash.Wyhash.hash(h ^ @backingInt(t.mode), t.text);
        }
        return h;
    }

    fn matchesNarrowing(
        c: *const SearchCache,
        live: *const live_mod.Live,
        q: *const query_mod.Query,
        tok: *const fuzzy.Token,
        lo: usize,
        hi: usize,
    ) bool {
        if (!c.complete or c.epoch != live.epoch) return false;
        if (tok.mode != c.mode or fuzzy.takesTypos(tok.text, tok.mode) != c.takes_typos) return false;
        if (c.has_scope != (q.scope != null)) return false;
        if (c.has_scope and (c.scope_lo != lo or c.scope_hi != hi)) return false;
        if (c.ext_hash != hashExts(q.exts.items) or c.kind != q.kind or c.apps != q.apps) return false;
        if (c.size_min != q.size_min or c.size_max != q.size_max) return false;
        if (c.mtime_min != q.mtime_min or c.mtime_max != q.mtime_max) return false;
        if (c.neg_hash != hashNeg(q.tokens.items)) return false;
        if (tok.text.len == 0 or c.token_len == 0 or tok.text.len < c.token_len) return false;
        const prev = c.token_buf[0..c.token_len];
        return if (tok.mode == .suffix)
            std.mem.endsWith(u8, tok.text, prev)
        else
            std.mem.startsWith(u8, tok.text, prev);
    }

    fn store(
        c: *SearchCache,
        gpa: std.mem.Allocator,
        live: *const live_mod.Live,
        q: *const query_mod.Query,
        tok: *const fuzzy.Token,
        lo: usize,
        hi: usize,
        ids: []const u32,
    ) void {
        if (tok.text.len > c.token_buf.len or ids.len > 16_384) {
            c.complete = false;
            return;
        }
        c.name_ids.clearRetainingCapacity();
        c.name_ids.appendSlice(gpa, ids) catch {
            c.complete = false;
            return;
        };
        @memcpy(c.token_buf[0..tok.text.len], tok.text);
        c.token_len = tok.text.len;
        c.epoch = live.epoch;
        c.mode = tok.mode;
        c.takes_typos = fuzzy.takesTypos(tok.text, tok.mode);
        c.has_scope = q.scope != null;
        c.scope_lo = lo;
        c.scope_hi = hi;
        c.ext_hash = hashExts(q.exts.items);
        c.kind = q.kind;
        c.apps = q.apps;
        c.size_min = q.size_min;
        c.size_max = q.size_max;
        c.mtime_min = q.mtime_min;
        c.mtime_max = q.mtime_max;
        c.neg_hash = hashNeg(q.tokens.items);
        c.complete = true;
    }
};

pub fn scopeRange(idx: *const index_read.Index, scope: ?[]const u8) ?[2]usize {
    const s = scope orelse return .{ 1, idx.n };
    if (std.mem.eql(u8, s, "/")) return .{ 1, idx.n };
    const e = idx.lookup(s) orelse return null;
    const d = idx.dirOf(e) orelse return null;
    return .{ idx.dirStart()[d], idx.dirEnd()[d] };
}

pub fn search(
    gpa: std.mem.Allocator,
    live: *const live_mod.Live,
    q: *const query_mod.Query,
    cache: ?*SearchCache,
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
                live,
                q,
                pos_toks[0..npos],
                neg_toks[0..nneg],
                lo,
                hi,
                now,
                cache,
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
            const e = bitmap_tier.unpackIdx(entry.key);
            const path = idx.pathBuf(e, &pbuf) orelse continue;
            const poff: u32 = @intCast(out.paths.items.len);
            try out.paths.appendSlice(gpa, path);
            out.hits.appendAssumeCapacity(.{
                .score = bitmap_tier.unpackScore(entry.key),
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
                .score = bitmap_tier.unpackScore(entry.key),
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

fn searchBase(
    gpa: std.mem.Allocator,
    live: *const live_mod.Live,
    q: *const query_mod.Query,
    pos: []const *const fuzzy.Token,
    neg: []const *const fuzzy.Token,
    lo: usize,
    hi: usize,
    now: u32,
    cache: ?*SearchCache,
    top: *TopK,
) !u8 {
    const idx = &live.base;
    var allow_ext: [4]u64 = @splat(0);
    if (q.exts.items.len > 0) {
        for (q.exts.items) |ex| {
            const s = idx.extSlot(ex);
            allow_ext[s / 64] |= @as(u64, 1) << @intCast(s % 64);
        }
    }

    var neg_dir_cache: std.AutoHashMapUnmanaged(u32, bool) = .empty;
    defer neg_dir_cache.deinit(gpa);

    if (pos.len == 1 and neg.len == 0) {
        if (cache) |c| {
            if (c.matchesNarrowing(live, q, pos[0], lo, hi)) {
                var next_ids: std.ArrayList(u32) = .empty;
                defer next_ids.deinit(gpa);
                for (c.name_ids.items) |kid| {
                    if (scoreNameSingle(idx, q, pos[0], neg, &allow_ext, kid)) |ns| {
                        try next_ids.append(gpa, kid);
                        try bitmap_tier.emitSingleEntries(gpa, live, q, lo, hi, now, kid, ns, neg, &neg_dir_cache, top);
                    }
                }
                c.store(gpa, live, q, pos[0], lo, hi, next_ids.items);
                return 0;
            }
        }
    }

    if (pos.len == 1 and pos[0].text.len >= 3) {
        const tok = pos[0];
        const done = try tryTrigramTier(gpa, live, q, tok, neg, &allow_ext, lo, hi, now, cache, &neg_dir_cache, top);
        if (done) return 1;
        top.items.clearRetainingCapacity();
        top.floor = 0;
        top.floor_score = std.math.minInt(i32);
        top.full = false;
    }

    if (pos.len == 1 and tokCanUseHeadBucket(pos[0])) {
        const tok = pos[0];
        const slice = idx.headSlice(fmt.charClass(tok.text[0]));
        const info = idx.nameInfo();
        const max_tok = fuzzy.maxCleanTokenBound(tok, 0);
        for (slice) |kid| {
            const ni = info[kid];
            if (top.full and ni.key > std.math.minInt(i8) and max_tok + @as(i32, ni.key) < top.floor_score) break;
            if (scoreNameSingle(idx, q, tok, neg, &allow_ext, kid)) |ns| {
                try bitmap_tier.emitSingleEntries(gpa, live, q, lo, hi, now, kid, ns, neg, &neg_dir_cache, top);
            }
        }
        return 2;
    }

    var cache_ids: std.ArrayList(u32) = .empty;
    defer cache_ids.deinit(gpa);
    try bitmap_tier.runBitmapTier(
        gpa,
        live,
        q,
        pos,
        neg,
        &allow_ext,
        lo,
        hi,
        now,
        &neg_dir_cache,
        top,
        if (cache != null) &cache_ids else null,
    );
    if (cache) |c| {
        if (pos.len == 1 and neg.len == 0 and cache_ids.items.len > 0 and cache_ids.items.len <= 16_384) {
            c.store(gpa, live, q, pos[0], lo, hi, cache_ids.items);
        }
    }
    return 2;
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
    cache: ?*SearchCache,
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
    const max_tok_no_len = fuzzy.maxCleanTokenBound(tok, 0);
    const primary = slices[0];
    const rest = slices[1..];
    var cursors: [63]usize = @splat(0);

    var matched_ids: std.ArrayList(u32) = .empty;
    defer matched_ids.deinit(gpa);
    const collect_cache = cache != null and neg.len == 0 and tok.mode != .fuzzy;

    for (primary) |kid| {
        const ni = info[kid];
        if (top.full and ni.key > std.math.minInt(i8) and max_tok_no_len + @as(i32, ni.key) < top.floor_score) {
            break;
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
            if (collect_cache and matched_ids.items.len <= 16_384) {
                try matched_ids.append(gpa, kid);
            }
            try bitmap_tier.emitSingleEntries(gpa, live, q, lo, hi, now, kid, ns, neg, neg_cache, top);
        }
    }
    top.compact();

    if (tok.mode != .fuzzy) {
        if (cache) |c| {
            if (neg.len == 0 and matched_ids.items.len <= 16_384) {
                c.store(gpa, live, q, tok, lo, hi, matched_ids.items);
            }
        }
        return true;
    }
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
