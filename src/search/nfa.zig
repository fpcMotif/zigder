const std = @import("std");
const fmt = @import("../index/fmt.zig");
const index_read = @import("../index/read.zig");
const fuzzy = @import("fuzzy_simd.zig");
const query_mod = @import("query.zig");
const measure = @import("../measure.zig");

extern "c" fn pthread_set_qos_class_self_np(qos_class: c_uint, relative_priority: c_int) c_int;
const QOS_USER_INTERACTIVE: c_uint = 0x21;
const WORK_STEP: usize = 256;
const SPIN_NS: u64 = 2_000_000;

pub const NWORKERS: usize = 5;
pub const NSHARDS: usize = NWORKERS + 1;

pub const NameHitEntry = struct {
    id: u32,
    score: i16,
    max_tot: i32,
    bits: u8,
    is_dot: bool,
    is_app: bool,
};

pub inline fn cheapNameBound(ni: fmt.NameInfo, tok: *const fuzzy.Token) i32 {
    if (ni.key == std.math.maxInt(i8)) return std.math.maxInt(i32);
    const k: i32 = ni.key;
    return switch (tok.mode) {
        .exact => 70 + k,
        .prefix => 60 + k,
        .suffix => 50 + k,
        .fuzzy => blk: {
            const m: i32 = @intCast(tok.text.len);
            const base = 24 * m + 8;
            if (tok.text.len == 0) break :blk k;
            const placed: i32 = if (ni.head != tok.text[0])
                0
            else if (ni.len == 255 or @as(i32, ni.len) == m)
                100
            else if (ni.stem == 255 or @as(i32, ni.stem) == m)
                80
            else
                30;
            break :blk base + placed + k;
        },
    };
}

const Constraint = struct {
    c: u8,
    dbl: bool,
    cnt: u32,

    fn asc(_: void, a: Constraint, b: Constraint) bool {
        return a.cnt < b.cnt;
    }
};

pub const TokPlan = struct {
    c0: u8,
    empty: bool,
    typos: bool,
    start_bm: usize,
    rest: [fmt.CLASSES * 2]Constraint,
    nrest: usize,
    seq: [64]u8,
    nseq: usize,
};

pub const WordMask = struct {
    any: u64,
    clean: u64,
    typo: u64,
};

pub fn buildTokPlan(idx: *const index_read.Index, tok: *const fuzzy.Token) TokPlan {
    const cc = idx.classCounts();
    const dc = idx.doubleCounts();
    var freq: [fmt.CLASSES]u8 = @splat(0);
    for (tok.text) |b| freq[fmt.charClass(b)] +|= 1;
    const empty = tok.text.len == 0;
    const typos = tok.start != 0 and !empty;
    const c0: u8 = if (empty) 0 else fmt.charClass(tok.text[0]);
    var p: TokPlan = .{
        .c0 = c0,
        .empty = empty,
        .typos = typos,
        .start_bm = if (typos) fmt.BM_START + fmt.startHash(tok.text[0]) else 0,
        .rest = undefined,
        .nrest = 0,
        .seq = undefined,
        .nseq = @min(tok.text.len, 64),
    };
    for (0..p.nseq) |i| p.seq[i] = fmt.charClass(tok.text[i]);
    if (!empty) {
        for (0..fmt.CLASSES) |c| {
            if (freq[c] == 0) continue;
            if (c != c0) {
                p.rest[p.nrest] = .{ .c = @intCast(c), .dbl = false, .cnt = cc[c] };
                p.nrest += 1;
            }
            if (freq[c] >= 2) {
                p.rest[p.nrest] = .{ .c = @intCast(c), .dbl = true, .cnt = dc[c] };
                p.nrest += 1;
            }
        }
        std.mem.sort(Constraint, p.rest[0..p.nrest], {}, Constraint.asc);
    }
    return p;
}

inline fn loadSingleVec(idx: *const index_read.Index, c: usize, w: usize) @Vector(4, u64) {
    const Vec4 = @Vector(4, u64);
    const b0: Vec4 = idx.bitmap(fmt.BM_FIRST + c)[w..][0..4].*;
    const b1: Vec4 = idx.bitmap(fmt.BM_SECOND + c)[w..][0..4].*;
    return b0 | b1;
}

inline fn loadConstraintVec(idx: *const index_read.Index, con: Constraint, w: usize) @Vector(4, u64) {
    if (con.dbl) {
        return idx.bitmap(fmt.BM_DOUBLE + con.c)[w..][0..4].*;
    }
    return loadSingleVec(idx, con.c, w);
}

inline fn loadSingleScalar(idx: *const index_read.Index, c: usize, w: usize) u64 {
    return idx.bitmap(fmt.BM_FIRST + c)[w] | idx.bitmap(fmt.BM_SECOND + c)[w];
}

inline fn loadConstraintScalar(idx: *const index_read.Index, con: Constraint, w: usize) u64 {
    if (con.dbl) {
        return idx.bitmap(fmt.BM_DOUBLE + con.c)[w];
    }
    return loadSingleScalar(idx, con.c, w);
}

fn evalVec4(idx: *const index_read.Index, p: *const TokPlan, w: usize) [4]WordMask {
    if (p.empty) return @splat(.{ .any = std.math.maxInt(u64), .clean = std.math.maxInt(u64), .typo = 0 });
    const Vec4 = @Vector(4, u64);
    var all_v: Vec4 = loadSingleVec(idx, p.c0, w);
    if (@reduce(.Or, all_v) == 0) return @splat(.{ .any = 0, .clean = 0, .typo = 0 });
    const typo_in: Vec4 = if (p.typos) idx.bitmap(p.start_bm)[w..][0..4].* & all_v else @splat(0);
    var one_v: Vec4 = @splat(0);
    for (p.rest[0..p.nrest]) |con| {
        const bw = loadConstraintVec(idx, con, w);
        if (p.typos) {
            one_v = (one_v & bw) | (all_v & ~bw & typo_in);
        }
        all_v &= bw;
        if (@reduce(.Or, all_v | one_v) == 0) return @splat(.{ .any = 0, .clean = 0, .typo = 0 });
    }
    var first: Vec4 = all_v | one_v;
    var second: Vec4 = @splat(0);
    var first1: Vec4 = @splat(0);
    var second1: Vec4 = @splat(0);
    for (p.seq[0..p.nseq], 0..) |c, ki| {
        const b0: Vec4 = idx.bitmap(fmt.BM_FIRST + c)[w..][0..4].*;
        const b1: Vec4 = idx.bitmap(fmt.BM_SECOND + c)[w..][0..4].*;
        if (ki > 0 and p.typos) {
            second1 = ((second1 | first1) & b1) | (second & typo_in);
            first1 = (first1 & b0) | (first & typo_in);
        }
        second = (second | first) & b1;
        first &= b0;
        if (@reduce(.Or, first | second | first1 | second1) == 0) return @splat(.{ .any = 0, .clean = 0, .typo = 0 });
    }
    const clean_v = (first | second) & all_v;
    const typo_v = (first | second | first1 | second1) & typo_in;
    const any_v = clean_v | typo_v;
    const any_a: [4]u64 = any_v;
    const clean_a: [4]u64 = clean_v;
    const typo_a: [4]u64 = typo_v;
    var out: [4]WordMask = undefined;
    inline for (0..4) |j| out[j] = .{ .any = any_a[j], .clean = clean_a[j], .typo = typo_a[j] };
    return out;
}

fn evalScalar(idx: *const index_read.Index, p: *const TokPlan, w: usize) WordMask {
    if (p.empty) return .{ .any = std.math.maxInt(u64), .clean = std.math.maxInt(u64), .typo = 0 };
    var all_w = loadSingleScalar(idx, p.c0, w);
    if (all_w == 0) return .{ .any = 0, .clean = 0, .typo = 0 };
    const typo_in = if (p.typos) idx.bitmap(p.start_bm)[w] & all_w else 0;
    var one_w: u64 = 0;
    for (p.rest[0..p.nrest]) |con| {
        const bw = loadConstraintScalar(idx, con, w);
        if (p.typos) {
            one_w = (one_w & bw) | (all_w & ~bw & typo_in);
        }
        all_w &= bw;
        if ((all_w | one_w) == 0) return .{ .any = 0, .clean = 0, .typo = 0 };
    }
    var first = all_w | one_w;
    var second: u64 = 0;
    var first1: u64 = 0;
    var second1: u64 = 0;
    for (p.seq[0..p.nseq], 0..) |c, ki| {
        const b0 = idx.bitmap(fmt.BM_FIRST + c)[w];
        const b1 = idx.bitmap(fmt.BM_SECOND + c)[w];
        if (ki > 0 and p.typos) {
            second1 = ((second1 | first1) & b1) | (second & typo_in);
            first1 = (first1 & b0) | (first & typo_in);
        }
        second = (second | first) & b1;
        first &= b0;
        if ((first | second | first1 | second1) == 0) return .{ .any = 0, .clean = 0, .typo = 0 };
    }
    const clean_w = (first | second) & all_w;
    const typo_w = (first | second | first1 | second1) & typo_in;
    return .{ .any = clean_w | typo_w, .clean = clean_w, .typo = typo_w };
}

const ScanCtx = struct {
    idx: *const index_read.Index,
    q: *const query_mod.Query,
    pos: []const *const fuzzy.Token,
    neg: []const *const fuzzy.Token,
    allow_ext: *const [4]u64,
    has_exts: bool,
    info: []const fmt.NameInfo,
    ne_off: []const u32,
    name_ext: []const u8,
    nprior: []const i8,
    noff: []const u32,
    names_ptr: [*]const u8,
    bm_sp0: []const u64,
    bm_sp1: []const u64,
    seed_floor: i32,
};

inline fn matchesAnyNeg(nm: []const u8, neg: []const *const fuzzy.Token) bool {
    for (neg) |nt| if (fuzzy.tokenMatches(nm, nt)) return true;
    return false;
}

fn evalWordSingle(
    alloc: std.mem.Allocator,
    ctx: *const ScanCtx,
    wi: usize,
    wm: WordMask,
    out_hits: *std.ArrayList(NameHitEntry),
    out_ok: *usize,
) !void {
    const idx = ctx.idx;
    const tok = ctx.pos[0];
    const space_w = ctx.bm_sp0[wi] | ctx.bm_sp1[wi];
    var bits = wm.any;
    while (bits != 0) {
        const bi = @ctz(bits);
        bits &= bits - 1;
        const kid: u32 = @intCast(wi * 64 + bi);
        if (kid >= idx.u) break;
        if (ctx.seed_floor > std.math.minInt(i32) and cheapNameBound(ctx.info[kid], tok) < ctx.seed_floor) continue;
        if (ctx.has_exts) {
            const s = ctx.name_ext[kid];
            if (((ctx.allow_ext[s / 64] >> @intCast(s % 64)) & 1) == 0) continue;
            if (s == 255 and !query_mod.Query.extOk(idx.uname(kid), ctx.q.exts.items)) continue;
        }
        const nm = idx.uname(kid);
        const clean_b = ((wm.clean >> @intCast(bi)) & 1) != 0;
        const typo_b = ((wm.typo >> @intCast(bi)) & 1) != 0;
        const spaced_b = ((space_w >> @intCast(bi)) & 1) != 0;
        const m = tok.knownMask(clean_b, typo_b, spaced_b);
        const wide: ?*const [64]u8 = if (nm.len <= 64) @ptrCast(ctx.names_ptr + ctx.noff[kid]) else null;
        const sc = fuzzy.tokenScore(nm, wide, m, tok) orelse continue;
        if (matchesAnyNeg(nm, ctx.neg)) continue;
        const s16: i16 = @intCast(std.math.clamp(sc, std.math.minInt(i16), std.math.maxInt(i16)));
        const is_dot = nm.len > 0 and nm[0] == '.';
        const is_app = std.mem.endsWith(u8, nm, ".app");
        const max_tweak: i32 = 10 + @as(i32, if (is_app) 25 else 0) - @as(i32, if (is_dot) 8 else 0);
        const max_tot: i32 = @as(i32, s16) + @as(i32, ctx.nprior[kid]) + max_tweak;
        if (max_tot < ctx.seed_floor) continue;
        out_ok.* += ctx.ne_off[kid + 1] - ctx.ne_off[kid];
        try out_hits.append(alloc, .{
            .id = kid,
            .score = s16,
            .max_tot = max_tot,
            .bits = 1,
            .is_dot = is_dot,
            .is_app = is_app,
        });
    }
}

fn evalWordGeneral(
    alloc: std.mem.Allocator,
    ctx: *const ScanCtx,
    wi: usize,
    bits_in: u64,
    tok_any: *const [8]u64,
    out_hits: *std.ArrayList(NameHitEntry),
    out_ok: *usize,
) !void {
    const idx = ctx.idx;
    var bits = bits_in;
    while (bits != 0) {
        const bi = @ctz(bits);
        bits &= bits - 1;
        const kid: u32 = @intCast(wi * 64 + bi);
        if (kid >= idx.u) break;
        const nm = idx.uname(kid);
        if (ctx.has_exts) {
            const s = ctx.name_ext[kid];
            if (((ctx.allow_ext[s / 64] >> @intCast(s % 64)) & 1) == 0) continue;
            if (s == 255 and !query_mod.Query.extOk(nm, ctx.q.exts.items)) continue;
        }
        var m: u64 = 0;
        var have_m = false;
        const wide: ?*const [64]u8 = if (nm.len <= 64) @ptrCast(ctx.names_ptr + ctx.noff[kid]) else null;
        var h_bits: u8 = 0;
        var h_score: i16 = 0;
        const bit_mask = @as(u64, 1) << @intCast(bi);
        for (ctx.pos, 0..) |tok, ti| {
            if ((tok_any[ti] & bit_mask) == 0) continue;
            if (tok.start != 0) {
                if (!have_m) {
                    m = fmt.nameMask(nm);
                    have_m = true;
                }
                if (!tok.fits(m)) continue;
            }
            if (fuzzy.tokenScore(nm, wide, m, tok)) |sc| {
                h_bits |= @as(u8, 1) << @intCast(ti);
                h_score +|= @intCast(std.math.clamp(sc, std.math.minInt(i16), std.math.maxInt(i16)));
            }
        }
        if (ctx.pos.len > 0 and h_bits == 0) continue;
        if (matchesAnyNeg(nm, ctx.neg)) continue;
        const is_dot = nm.len > 0 and nm[0] == '.';
        const is_app = std.mem.endsWith(u8, nm, ".app");
        const max_tweak: i32 = 10 + @as(i32, if (is_app) 25 else 0) - @as(i32, if (is_dot) 8 else 0);
        const max_tot: i32 = @as(i32, h_score) + @as(i32, ctx.nprior[kid]) + max_tweak;
        out_ok.* += ctx.ne_off[kid + 1] - ctx.ne_off[kid];
        try out_hits.append(alloc, .{
            .id = kid,
            .score = h_score,
            .max_tot = max_tot,
            .bits = h_bits,
            .is_dot = is_dot,
            .is_app = is_app,
        });
    }
}

fn scanRange(
    alloc: std.mem.Allocator,
    idx: *const index_read.Index,
    q: *const query_mod.Query,
    pos: []const *const fuzzy.Token,
    neg: []const *const fuzzy.Token,
    allow_ext: *const [4]u64,
    plans: []const TokPlan,
    seed_floor: i32,
    w_start: usize,
    w_end: usize,
    out_hits: *std.ArrayList(NameHitEntry),
    out_ok: *usize,
) !void {
    const ctx: ScanCtx = .{
        .idx = idx,
        .q = q,
        .pos = pos,
        .neg = neg,
        .allow_ext = allow_ext,
        .has_exts = q.exts.items.len > 0,
        .info = idx.nameInfo(),
        .ne_off = idx.nameEntsOff(),
        .name_ext = idx.nameExt(),
        .nprior = idx.namePrior(),
        .noff = idx.nameOff(),
        .names_ptr = idx.names().ptr,
        .bm_sp0 = idx.bitmap(fmt.BM_FIRST + 38),
        .bm_sp1 = idx.bitmap(fmt.BM_SECOND + 38),
        .seed_floor = seed_floor,
    };
    var w = w_start;

    if (pos.len == 1) {
        const plan = &plans[0];
        while (w + 4 <= w_end) : (w += 4) {
            const wms = evalVec4(idx, plan, w);
            inline for (0..4) |j| {
                if (wms[j].any != 0) try evalWordSingle(alloc, &ctx, w + j, wms[j], out_hits, out_ok);
            }
        }
        while (w < w_end) : (w += 1) {
            const wm = evalScalar(idx, plan, w);
            if (wm.any != 0) try evalWordSingle(alloc, &ctx, w, wm, out_hits, out_ok);
        }
        return;
    }

    while (w + 4 <= w_end) : (w += 4) {
        var any_v: [4]u64 = if (pos.len == 0) .{ std.math.maxInt(u64), std.math.maxInt(u64), std.math.maxInt(u64), std.math.maxInt(u64) } else .{ 0, 0, 0, 0 };
        var per_tok: [4][8]u64 = @splat(@splat(0));
        for (plans, 0..) |*p, ti| {
            const wms = evalVec4(idx, p, w);
            inline for (0..4) |j| {
                per_tok[j][ti] = wms[j].any;
                any_v[j] |= wms[j].any;
            }
        }
        inline for (0..4) |j| {
            if (any_v[j] != 0) try evalWordGeneral(alloc, &ctx, w + j, any_v[j], &per_tok[j], out_hits, out_ok);
        }
    }
    while (w < w_end) : (w += 1) {
        var any: u64 = if (pos.len == 0) std.math.maxInt(u64) else 0;
        var tok_any: [8]u64 = @splat(0);
        for (plans, 0..) |*p, ti| {
            tok_any[ti] = evalScalar(idx, p, w).any;
            any |= tok_any[ti];
        }
        if (any != 0) try evalWordGeneral(alloc, &ctx, w, any, &tok_any, out_hits, out_ok);
    }
}

const Job = struct {
    idx: *const index_read.Index,
    q: *const query_mod.Query,
    pos: []const *const fuzzy.Token,
    neg: []const *const fuzzy.Token,
    allow_ext: *const [4]u64,
    plans: []const TokPlan,
    seed_floor: i32,
};

pub const Pool = struct {
    threads: [NWORKERS]std.Thread = undefined,
    active_workers: usize = 0,
    mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    cond: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER,
    gen: std.atomic.Value(u32) = .init(0),
    next_word: std.atomic.Value(usize) = .init(0),
    done_count: std.atomic.Value(u32) = .init(0),
    sleeping: std.atomic.Value(u32) = .init(0),
    stop: std.atomic.Value(bool) = .init(false),
    job: Job = undefined,
    shard_hits: [NSHARDS]std.ArrayList(NameHitEntry) = @splat(.empty),
    shard_ok: [NSHARDS]usize = @splat(0),
    shard_err: [NSHARDS]bool = @splat(false),

    pub fn create(gpa: std.mem.Allocator) !*Pool {
        const p = try gpa.create(Pool);
        p.* = .{};
        return p;
    }

    pub fn destroy(self: *Pool, gpa: std.mem.Allocator) void {
        if (self.active_workers > 0) {
            self.stop.store(true, .seq_cst);
            _ = std.c.pthread_mutex_lock(&self.mutex);
            _ = std.c.pthread_cond_broadcast(&self.cond);
            _ = std.c.pthread_mutex_unlock(&self.mutex);
            for (self.threads[0..self.active_workers]) |t| t.join();
        }
        for (&self.shard_hits) |*sh| sh.deinit(std.heap.c_allocator);
        gpa.destroy(self);
    }

    fn drainChunks(self: *Pool, shard: usize) void {
        const j = &self.job;
        while (true) {
            const w0 = self.next_word.fetchAdd(WORK_STEP, .monotonic);
            if (w0 >= j.idx.words) break;
            const w1 = @min(w0 + WORK_STEP, j.idx.words);
            scanRange(
                std.heap.c_allocator,
                j.idx,
                j.q,
                j.pos,
                j.neg,
                j.allow_ext,
                j.plans,
                j.seed_floor,
                w0,
                w1,
                &self.shard_hits[shard],
                &self.shard_ok[shard],
            ) catch {
                self.shard_err[shard] = true;
                break;
            };
        }
    }

    fn workerMain(self: *Pool, shard: usize) void {
        _ = pthread_set_qos_class_self_np(QOS_USER_INTERACTIVE, 0);
        var last_gen: u32 = 0;
        while (true) {
            var spin_t0: u64 = 0;
            var iter: usize = 0;
            while (self.gen.load(.acquire) == last_gen) {
                if (self.stop.load(.acquire)) return;
                iter += 1;
                if ((iter & 255) != 0) {
                    std.atomic.spinLoopHint();
                    continue;
                }
                const now_ns = measure.nanos();
                if (spin_t0 == 0) spin_t0 = now_ns;
                if (now_ns -| spin_t0 < SPIN_NS) {
                    std.atomic.spinLoopHint();
                } else {
                    _ = std.c.pthread_mutex_lock(&self.mutex);
                    _ = self.sleeping.fetchAdd(1, .seq_cst);
                    while (!self.stop.load(.seq_cst) and self.gen.load(.seq_cst) == last_gen) {
                        _ = std.c.pthread_cond_wait(&self.cond, &self.mutex);
                    }
                    _ = self.sleeping.fetchSub(1, .seq_cst);
                    _ = std.c.pthread_mutex_unlock(&self.mutex);
                    spin_t0 = 0;
                    iter = 0;
                }
            }
            if (self.stop.load(.acquire)) return;
            last_gen = self.gen.load(.acquire);
            self.drainChunks(shard);
            _ = self.done_count.fetchAdd(1, .release);
        }
    }

    pub fn runScan(
        self: *Pool,
        gpa: std.mem.Allocator,
        idx: *const index_read.Index,
        q: *const query_mod.Query,
        pos: []const *const fuzzy.Token,
        neg: []const *const fuzzy.Token,
        allow_ext: *const [4]u64,
        plans: []const TokPlan,
        seed_floor: i32,
        matched_names: *std.ArrayList(NameHitEntry),
    ) !usize {
        for (0..NSHARDS) |s| {
            self.shard_hits[s].clearRetainingCapacity();
            self.shard_ok[s] = 0;
            self.shard_err[s] = false;
        }

        if (idx.words < 2048) {
            try scanRange(std.heap.c_allocator, idx, q, pos, neg, allow_ext, plans, seed_floor, 0, idx.words, &self.shard_hits[0], &self.shard_ok[0]);
            try matched_names.appendSlice(gpa, self.shard_hits[0].items);
            return self.shard_ok[0];
        }

        if (self.active_workers == 0 and !self.stop.load(.acquire)) {
            while (self.active_workers < NWORKERS) {
                const s = self.active_workers + 1;
                self.threads[self.active_workers] = std.Thread.spawn(.{ .stack_size = 64 * 1024 }, workerMain, .{ self, s }) catch break;
                self.active_workers += 1;
            }
        }

        const n_shards = self.active_workers + 1;
        self.job = .{
            .idx = idx,
            .q = q,
            .pos = pos,
            .neg = neg,
            .allow_ext = allow_ext,
            .plans = plans,
            .seed_floor = seed_floor,
        };
        if (self.active_workers > 0) {
            self.next_word.store(0, .release);
            self.done_count.store(0, .release);
            const next = self.gen.load(.monotonic) +% 1;
            self.gen.store(next, .seq_cst);
            if (self.sleeping.load(.seq_cst) != 0) {
                _ = std.c.pthread_mutex_lock(&self.mutex);
                _ = std.c.pthread_cond_broadcast(&self.cond);
                _ = std.c.pthread_mutex_unlock(&self.mutex);
            }
        }

        self.drainChunks(0);

        while (self.done_count.load(.acquire) < self.active_workers) {
            std.atomic.spinLoopHint();
        }

        var total_hits: usize = 0;
        var total_ok: usize = 0;
        for (0..n_shards) |s| {
            if (self.shard_err[s]) return error.OutOfMemory;
            total_hits += self.shard_hits[s].items.len;
            total_ok += self.shard_ok[s];
        }
        try matched_names.ensureTotalCapacity(gpa, matched_names.items.len + total_hits);
        for (0..n_shards) |s| {
            matched_names.appendSliceAssumeCapacity(self.shard_hits[s].items);
            if (self.shard_hits[s].capacity > 8192) self.shard_hits[s].clearAndFree(std.heap.c_allocator);
        }
        return total_ok;
    }
};
