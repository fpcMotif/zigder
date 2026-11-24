const std = @import("std");
const fmt = @import("index_fmt.zig");
const walk = @import("walk.zig");
const fuzzy = @import("fuzzy_simd.zig");
const query_mod = @import("query.zig");
const measure = @import("measure.zig");

pub const BaselineHit = struct {
    score: i32,
    idx: u32,
    kind: u8,
    size: u64,
    mtime: u32,
};

fn founderPathBuf(f: *const fmt.FounderIndex, i: usize, buf: []u8) ?[]const u8 {
    if (i == 0) {
        if (buf.len < 1) return null;
        buf[0] = '/';
        return buf[0..1];
    }
    const de = f.dirEntry();
    const dp = f.dirParent();
    const par = f.parent();
    var chain: [256]u32 = undefined;
    chain[0] = @intCast(i);
    var k: usize = 1;
    var d = par[i];
    while (d != 0 and k < chain.len) {
        chain[k] = de[d];
        k += 1;
        d = dp[d];
    }
    var len: usize = 0;
    var j = k;
    while (j > 0) {
        j -= 1;
        const nm = f.uname(f.entName()[chain[j]]);
        if (len + 1 + nm.len > buf.len) return null;
        buf[len] = '/';
        len += 1;
        @memcpy(buf[len .. len + nm.len], nm);
        len += nm.len;
    }
    return buf[0..len];
}

pub inline fn rankTweaks(is_dot: bool, is_app: bool, kind: u8, mtime: u32, now: u32) i32 {
    var s: i32 = 0;
    if (is_dot) s -= 8;
    if ((kind & walk.FLAG_HIDDEN) != 0) s -= 8;
    const base_kind = kind & 3;
    if ((base_kind == walk.KIND_DIR or base_kind == walk.KIND_LINK) and is_app) s += 25;
    const age = now -| mtime;
    if (age <= 86_400) {
        s += 10;
    } else if (age <= 604_800) {
        s += 7;
    } else if (age <= 2_592_000) {
        s += 4;
    } else if (age <= 31_536_000) {
        s += 1;
    }
    return s;
}

inline fn packKey(score: i32, idx: u32) u64 {
    const sc: u64 = @intCast(@as(i64, score) - @as(i64, std.math.minInt(i32)));
    return (sc << 32) | (~idx);
}

inline fn unpackScore(k: u64) i32 {
    return @intCast(@as(i64, @intCast(k >> 32)) + @as(i64, std.math.minInt(i32)));
}

inline fn unpackIdx(k: u64) u32 {
    return ~@as(u32, @truncate(k));
}

pub fn baselineFounderSearch(
    gpa: std.mem.Allocator,
    f: *const fmt.FounderIndex,
    q: *const query_mod.Query,
    out_hits: *std.ArrayList(BaselineHit),
) !u64 {
    const t0 = measure.nanos();
    out_hits.clearRetainingCapacity();
    if (q.limit == 0) return 0;

    var lo: usize = 1;
    var hi: usize = f.n;
    if (q.scope) |sc| {
        const e = f.lookup(sc) orelse return 0;
        const d = f.dirOf(e) orelse return 0;
        lo = f.dirStart()[d];
        hi = f.dirEnd()[d];
    }

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
        } else {
            if (npos < pos_toks.len) {
                pos_toks[npos] = tok;
                npos += 1;
            }
        }
    }

    const words = f.words;
    const NameMatch = struct { id: u32, score: i16, bits: u8, is_dot: bool, is_app: bool, ok: bool };
    var matches: std.ArrayList(NameMatch) = .empty;
    defer matches.deinit(gpa);

    var tok_bitmaps: [8][41]usize = undefined;
    var tok_class_cnt: [8]usize = @splat(0);
    for (0..npos) |ti| {
        var mask = pos_toks[ti].mask;
        var cnt: usize = 0;
        while (mask != 0) {
            const c = @ctz(mask);
            mask &= mask - 1;
            tok_bitmaps[ti][cnt] = c;
            cnt += 1;
        }
        tok_class_cnt[ti] = cnt;
    }

    const noff = f.nameOff();
    const nbytes = f.names();
    const map_ptr = f.map.ptr;
    const names_abs = f.off[@backingInt(fmt.FSec.names)];

    var allow_ext: [4]u64 = @splat(0);
    if (q.exts.items.len > 0) {
        const table = f.extTable();
        for (q.exts.items) |ex| {
            var slot: u8 = 255;
            for (1..255) |si| {
                if (table[si][0] == ex.len and std.mem.eql(u8, table[si][1 .. 1 + ex.len], ex)) {
                    slot = @intCast(si);
                    break;
                }
            }
            allow_ext[slot / 64] |= @as(u64, 1) << @intCast(slot % 64);
        }
    }
    const name_ext = f.nameExt();

    var w: usize = 0;
    while (w < words) : (w += 1) {
        var any: u64 = if (npos == 0) std.math.maxInt(u64) else 0;
        for (0..npos) |ti| {
            const tok = pos_toks[ti];
            var all_w: u64 = std.math.maxInt(u64);
            const start_w: u64 = if (tok.start != 0) f.bitmap(fmt.BM_START + fmt.startHash(tok.text[0]))[w] else 0;
            var one_w: u64 = 0;
            for (0..tok_class_cnt[ti]) |ci| {
                const c = tok_bitmaps[ti][ci];
                const bw = f.bitmap(fmt.BM_FIRST + c)[w] | f.bitmap(fmt.BM_SECOND + c)[w];
                one_w = (one_w & bw) | (all_w & ~bw & start_w);
                all_w &= bw;
                if ((all_w | one_w) == 0) break;
            }
            any |= all_w | one_w;
        }
        if (w == words - 1 and (f.u & 63) != 0) {
            any &= (@as(u64, 1) << @intCast(f.u & 63)) - 1;
        }
        if (any == 0) continue;

        while (any != 0) {
            const bit_i = @ctz(any);
            any &= any - 1;
            const k: usize = w * 64 + bit_i;
            if (k >= f.u) break;
            const a = noff[k];
            const b = noff[k + 1];
            const nm = nbytes[a..b];
            const wide: ?*const [64]u8 = if (b - a <= 64 and names_abs + a + 64 <= f.map.len)
                @ptrCast(map_ptr + names_abs + a)
            else
                null;
            const mask = fmt.nameMask(nm);
            var total_s: i16 = 0;
            var bits: u8 = 0;
            for (0..npos) |ti| {
                const tok = pos_toks[ti];
                if (tok.fits(mask)) {
                    if (fuzzy.tokenScore(nm, wide, mask, tok)) |sc| {
                        bits |= @as(u8, 1) << @intCast(ti);
                        const clamped: i16 = @intCast(std.math.clamp(sc, std.math.minInt(i16), std.math.maxInt(i16)));
                        total_s +|= clamped;
                    }
                }
            }
            var neg_hit = false;
            for (0..nneg) |ni| {
                if (fuzzy.tokenMatches(nm, neg_toks[ni])) {
                    neg_hit = true;
                    break;
                }
            }
            var ext_ok = true;
            if (q.exts.items.len > 0) {
                const slot = name_ext[k];
                if (((allow_ext[slot / 64] >> @intCast(slot % 64)) & 1) == 0) {
                    ext_ok = false;
                } else if (slot == 255 and !query_mod.Query.extOk(nm, q.exts.items)) {
                    ext_ok = false;
                }
            }
            const ok = (npos == 0 or bits != 0) and !neg_hit and ext_ok;
            if (ok) {
                const is_dot = nm.len > 0 and nm[0] == '.';
                const is_app = std.mem.endsWith(u8, nm, ".app");
                try matches.append(gpa, .{
                    .id = @intCast(k),
                    .score = total_s,
                    .bits = bits,
                    .is_dot = is_dot,
                    .is_app = is_app,
                    .ok = ok,
                });
            }
        }
    }

    const ne_off = f.nameEntsOff();
    const ne = f.nameEnts();
    const kind_arr = f.kind();
    const mtime_arr = f.mtime();
    const parent_arr = f.parent();
    const dprior = f.dirPrior();
    const big = f.big();
    const sz_raw = f.sizeRaw();
    const now = query_mod.nowSecs();

    var top_buf: std.ArrayList(u64) = .empty;
    defer top_buf.deinit(gpa);
    var floor: u64 = 0;

    var pbuf: [2048]u8 = undefined;
    for (matches.items) |m| {
        const s_idx = ne_off[m.id];
        const e_idx = ne_off[m.id + 1];
        for (ne[s_idx..e_idx]) |ent| {
            if (ent < lo or ent >= hi) continue;
            const kv = kind_arr[ent];
            if (!q.kindOk(kv)) continue;
            if (q.size_min != 0 or q.size_max != std.math.maxInt(u64)) {
                const sz = fmt.unpackSize(sz_raw[ent], 1, big);
                if (sz < q.size_min or sz > q.size_max) continue;
            }
            const mt = mtime_arr[ent];
            if (mt < q.mtime_min or mt > q.mtime_max) continue;
            if (npos > 1 or nneg > 0) {
                const full_p = founderPathBuf(f, ent, &pbuf) orelse continue;
                if (q.matchPath(full_p, kv, fmt.unpackSize(sz_raw[ent], 1, big), mt)) |sc| {
                    const tot = sc + dprior[parent_arr[ent]] + rankTweaks(m.is_dot, m.is_app, kv, mt, now);
                    const pk = packKey(tot, ent);
                    if (pk > floor) {
                        try top_buf.append(gpa, pk);
                        if (top_buf.items.len >= @max(q.limit * 2, 64)) {
                            std.mem.sort(u64, top_buf.items, {}, std.sort.desc(u64));
                            top_buf.shrinkRetainingCapacity(q.limit);
                            floor = top_buf.items[q.limit - 1];
                        }
                    }
                }
                continue;
            }
            const tot = @as(i32, m.score) + dprior[parent_arr[ent]] + rankTweaks(m.is_dot, m.is_app, kv, mt, now);
            const pk = packKey(tot, ent);
            if (pk > floor) {
                try top_buf.append(gpa, pk);
                if (top_buf.items.len >= @max(q.limit * 2, 64)) {
                    std.mem.sort(u64, top_buf.items, {}, std.sort.desc(u64));
                    top_buf.shrinkRetainingCapacity(q.limit);
                    floor = top_buf.items[q.limit - 1];
                }
            }
        }
    }

    std.mem.sort(u64, top_buf.items, {}, std.sort.desc(u64));
    const take = @min(top_buf.items.len, q.limit);
    for (top_buf.items[0..take]) |pk| {
        const ent = unpackIdx(pk);
        try out_hits.append(gpa, .{
            .score = unpackScore(pk),
            .idx = ent,
            .kind = kind_arr[ent],
            .size = fmt.unpackSize(sz_raw[ent], 1, big),
            .mtime = mtime_arr[ent],
        });
    }
    return (measure.nanos() - t0) / 1000;
}
