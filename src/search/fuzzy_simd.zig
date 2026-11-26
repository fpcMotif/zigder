const std = @import("std");
const fmt = @import("../index/fmt.zig");

pub const Mode = enum {
    fuzzy,
    exact,
    prefix,
    suffix,
};

pub const TYPO_MIN_LEN: usize = 5;
pub const TYPO_COST: i32 = 60;

pub const SCORE_MATCH: i32 = 16;
pub const GAP_START: i32 = -3;
pub const GAP_EXT: i32 = -1;
pub const BONUS_BOUNDARY: i32 = 8;
pub const BONUS_CAMEL: i32 = 7;
pub const BONUS_CONSEC: i32 = 4;

pub const Token = struct {
    text: []u8,
    mask: u64,
    mode: Mode,
    negate: bool,
    loose: u64,
    start: u64,

    pub inline fn fits(self: *const Token, m: u64) bool {
        const miss = self.mask & ~m;
        return (miss == 0) or ((((miss & ~self.loose) | (miss & (miss -% 1))) == 0) and ((m & self.start) != 0));
    }

    pub inline fn knownMask(self: *const Token, clean: bool, start_flag: bool, spaced: bool) u64 {
        return (if (clean) self.mask else @as(u64, 0)) |
            (if (start_flag) self.start else @as(u64, 0)) |
            (if (spaced) fmt.charBit(' ') else @as(u64, 0));
    }
};

pub inline fn takesTypos(text: []const u8, mode: Mode) bool {
    return mode == .fuzzy and text.len >= TYPO_MIN_LEN;
}

const Class = enum {
    lower,
    upper,
    digit,
    delim,
    other,
};

inline fn charClassScore(b: u8) Class {
    return switch (b) {
        'a'...'z' => .lower,
        'A'...'Z' => .upper,
        '0'...'9' => .digit,
        ' ', '_', '-', '.', '/', '(', ')', '[', ']', ',', '+', '@' => .delim,
        else => .other,
    };
}

inline fn bonus(prev: Class, cur: Class) i32 {
    if (prev == .delim and cur != .delim) return BONUS_BOUNDARY;
    if ((prev == .lower and cur == .upper) or ((prev == .lower or prev == .upper) and cur == .digit)) return BONUS_CAMEL;
    return 0;
}

inline fn lenPenalty(name_len: usize) i32 {
    return @divTrunc(@min(@as(i32, @intCast(name_len)), 80), 3);
}

inline fn stemPos(name: []const u8, off: usize) usize {
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |p| {
        if (p > off) return p;
    }
    return name.len;
}

pub fn eqFold(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (fmt.fold(x) != fmt.fold(y)) return false;
    }
    return true;
}

pub fn findCi(name: []const u8, q: []const u8) ?usize {
    if (q.len == 0) return 0;
    if (q.len > name.len) return null;
    const limit = name.len - q.len + 1;
    for (0..limit) |i| {
        var ok = true;
        for (0..q.len) |j| {
            if (fmt.fold(name[i + j]) != q[j]) {
                ok = false;
                break;
            }
        }
        if (ok) return i;
    }
    return null;
}

pub fn isSubseq(name: []const u8, q: []const u8) bool {
    if (q.len == 0) return true;
    var j: usize = 0;
    for (name) |b| {
        if (fmt.fold(b) == q[j]) {
            j += 1;
            if (j == q.len) return true;
        }
    }
    return false;
}

pub fn prefixScore(name: []const u8, q: []const u8, cap: i32) ?i32 {
    if (q.len == 0) return 0;
    const off: usize = @intFromBool(name.len > 1 and name[0] == '.');
    const end = off + q.len;
    if ((off == 1 and q[0] == '.') or name.len < end) return null;
    for (name[off..end], q) |a, b| {
        if (fmt.fold(a) != b) return null;
    }
    var first = bonus(.delim, charClassScore(name[off]));
    var score: i32 = SCORE_MATCH + first * 2;
    for (off + 1..end) |i| {
        const b = bonus(charClassScore(name[i - 1]), charClassScore(name[i]));
        if (b >= BONUS_BOUNDARY and b > first) first = b;
        score += SCORE_MATCH + @max(@max(b, first), BONUS_CONSEC);
    }
    const placed: i32 = if (end == name.len)
        100
    else if (name[end] == '.' and std.mem.indexOfScalar(u8, name[end + 1 ..], '.') == null)
        80
    else
        30;
    return score + @min(placed, cap) - lenPenalty(name.len);
}

inline fn singleScore(name: []const u8, i: usize, cap: i32) i32 {
    const prev_c = if (i == 0) Class.delim else charClassScore(name[i - 1]);
    var score = SCORE_MATCH + bonus(prev_c, charClassScore(name[i])) * 2;
    const off: usize = @intFromBool(name.len > 1 and name[0] == '.');
    if (i == off) {
        const stem = stemPos(name, off);
        const placed: i32 = if (i + 1 == name.len) 100 else if (i + 1 == stem) 80 else 30;
        score += @min(cap, placed);
    }
    return score - lenPenalty(name.len);
}

fn fuzzyMasked(name: []const u8, src: *const [64]u8, q: []const u8, cap: i32) ?i32 {
    const Vec16 = @Vector(16, u8);
    const v_a: Vec16 = @splat('A');
    const v_26: Vec16 = @splat(26);
    const v_32: Vec16 = @splat(0x20);
    const v_0: Vec16 = @splat(0);

    var masks: [32]u64 = undefined;
    var end: usize = 0;
    var from: usize = 0;

    if (name.len <= 16) {
        const x0: Vec16 = src[0..16].*;
        const f0 = x0 | @select(u8, (x0 -% v_a) < v_26, v_32, v_0);
        const valid16: u16 = @intCast((@as(u32, 1) << @intCast(name.len)) - 1);
        for (0..q.len) |i| {
            const c = q[i];
            var m: u64 = 0;
            var found_prev = false;
            var p = i;
            while (p > 0) {
                p -= 1;
                if (q[p] == c) {
                    m = masks[p];
                    found_prev = true;
                    break;
                }
            }
            if (!found_prev) {
                const m0: u16 = @bitCast(f0 == @as(Vec16, @splat(c)));
                m = m0 & valid16;
            }
            masks[i] = m;
            const x = (m >> @intCast(from)) << @intCast(from);
            if (x == 0) return null;
            end = @ctz(x);
            from = end + 1;
        }
    } else if (name.len <= 32) {
        const x0: Vec16 = src[0..16].*;
        const x1: Vec16 = src[16..32].*;
        const f0 = x0 | @select(u8, (x0 -% v_a) < v_26, v_32, v_0);
        const f1 = x1 | @select(u8, (x1 -% v_a) < v_26, v_32, v_0);
        const valid32: u32 = @intCast((@as(u64, 1) << @intCast(name.len)) - 1);
        for (0..q.len) |i| {
            const c = q[i];
            var m: u64 = 0;
            var found_prev = false;
            var p = i;
            while (p > 0) {
                p -= 1;
                if (q[p] == c) {
                    m = masks[p];
                    found_prev = true;
                    break;
                }
            }
            if (!found_prev) {
                const v_c: Vec16 = @splat(c);
                const m0: u16 = @bitCast(f0 == v_c);
                const m1: u16 = @bitCast(f1 == v_c);
                m = (@as(u32, m0) | (@as(u32, m1) << 16)) & valid32;
            }
            masks[i] = m;
            const x = (m >> @intCast(from)) << @intCast(from);
            if (x == 0) return null;
            end = @ctz(x);
            from = end + 1;
        }
    } else {
        var folded: [4]Vec16 = undefined;
        inline for (0..4) |chunk| {
            const x: Vec16 = src[chunk * 16 ..][0..16].*;
            const is_upper = (x -% v_a) < v_26;
            folded[chunk] = x | @select(u8, is_upper, v_32, v_0);
        }
        const shift: u7 = @intCast(64 - name.len);
        const valid: u64 = if (shift >= 64) 0 else @as(u64, std.math.maxInt(u64)) >> @intCast(shift);
        for (0..q.len) |i| {
            const c = q[i];
            var m: u64 = 0;
            var found_prev = false;
            var p = i;
            while (p > 0) {
                p -= 1;
                if (q[p] == c) {
                    m = masks[p];
                    found_prev = true;
                    break;
                }
            }
            if (!found_prev) {
                const v_c: Vec16 = @splat(c);
                const m0: u16 = @bitCast(folded[0] == v_c);
                const m1: u16 = @bitCast(folded[1] == v_c);
                const m2: u16 = @bitCast(folded[2] == v_c);
                const m3: u16 = @bitCast(folded[3] == v_c);
                m = (@as(u64, m0) | (@as(u64, m1) << 16) | (@as(u64, m2) << 32) | (@as(u64, m3) << 48)) & valid;
            }
            masks[i] = m;
            const x = if (from < 64) (m >> @intCast(from)) << @intCast(from) else 0;
            if (x == 0) return null;
            end = @ctz(x);
            from = end + 1;
        }
    }

    if (q.len == 1) return singleScore(name, end, cap);

    var start = end + 1;
    var k = q.len;
    while (k > 0) {
        k -= 1;
        const s_hi: u7 = @intCast(64 - start);
        const hi_mask: u64 = if (s_hi >= 64) 0 else @as(u64, std.math.maxInt(u64)) >> @intCast(s_hi);
        const x = masks[k] & hi_mask;
        if (x == 0) return null;
        start = 63 - @clz(x);
    }
    return scorePositionsMasked(name, q, cap, start, end, &masks);
}

fn scorePositionsMasked(
    name: []const u8,
    q: []const u8,
    cap: i32,
    start: usize,
    end: usize,
    masks: *const [32]u64,
) ?i32 {
    var score: i32 = 0;
    var at = start;
    var first_bonus: i32 = 0;
    for (0..q.len) |k| {
        var run = false;
        if (k > 0) {
            const last = at;
            const f = last + 1;
            if (f > end or f >= 64) return null;
            const lo_mask = (@as(u64, std.math.maxInt(u64)) << @intCast(f));
            const hi_mask = @as(u64, std.math.maxInt(u64)) >> @intCast(63 - end);
            const x = masks[k] & lo_mask & hi_mask;
            if (x == 0) return null;
            at = @ctz(x);
            run = (at == last + 1);
            if (!run) score += GAP_START + @as(i32, @intCast(at - last - 2)) * GAP_EXT;
        }
        const prev_c = if (at == 0) Class.delim else charClassScore(name[at - 1]);
        var b = bonus(prev_c, charClassScore(name[at]));
        if (run) {
            if (b >= BONUS_BOUNDARY and b > first_bonus) first_bonus = b;
            b = @max(@max(b, first_bonus), BONUS_CONSEC);
        } else {
            first_bonus = b;
        }
        score += SCORE_MATCH + (if (k == 0) b * 2 else b);
    }
    return finishFuzzyScore(name, q.len, cap, start, end, score);
}

fn finishFuzzyScore(name: []const u8, qlen: usize, cap: i32, start: usize, end: usize, score: i32) i32 {
    const off: usize = @intFromBool(name.len > 1 and name[0] == '.');
    const placed: i32 = if (start != off or end + 1 - start != qlen)
        0
    else if (end + 1 == name.len)
        100
    else if (end + 1 == stemPos(name, off))
        80
    else
        30;
    return score + @min(placed, cap) - lenPenalty(name.len);
}

fn findFolded(s: []const u8, c: u8) ?usize {
    for (s, 0..) |b, i| {
        if (fmt.fold(b) == c) return i;
    }
    return null;
}

fn rfindFolded(s: []const u8, c: u8) ?usize {
    var i = s.len;
    while (i > 0) {
        i -= 1;
        if (fmt.fold(s[i]) == c) return i;
    }
    return null;
}

fn fuzzyScalar(name: []const u8, q: []const u8, cap: i32) ?i32 {
    var end: usize = 0;
    var from: usize = 0;
    for (q) |c| {
        const rel = findFolded(name[from..], c) orelse return null;
        end = from + rel;
        from = end + 1;
    }
    if (q.len == 1) return singleScore(name, end, cap);
    var start = end + 1;
    var k = q.len;
    while (k > 0) {
        k -= 1;
        start = rfindFolded(name[0..start], q[k]) orelse return null;
    }
    var score: i32 = 0;
    var at = start;
    var first_bonus: i32 = 0;
    for (0..q.len) |ki| {
        var run = false;
        if (ki > 0) {
            const last = at;
            const rel = findFolded(name[last + 1 .. end + 1], q[ki]) orelse return null;
            at = last + 1 + rel;
            run = (at == last + 1);
            if (!run) score += GAP_START + @as(i32, @intCast(at - last - 2)) * GAP_EXT;
        }
        const prev_c = if (at == 0) Class.delim else charClassScore(name[at - 1]);
        var b = bonus(prev_c, charClassScore(name[at]));
        if (run) {
            if (b >= BONUS_BOUNDARY and b > first_bonus) first_bonus = b;
            b = @max(@max(b, first_bonus), BONUS_CONSEC);
        } else {
            first_bonus = b;
        }
        score += SCORE_MATCH + (if (ki == 0) b * 2 else b);
    }
    return finishFuzzyScore(name, q.len, cap, start, end, score);
}

pub fn fuzzyScoreCapped(name: []const u8, wide: ?*const [64]u8, q: []const u8, cap: i32) ?i32 {
    if (q.len == 0) return 0;
    if (prefixScore(name, q, cap)) |s| return s;
    if (name.len <= 64 and q.len <= 32) {
        if (wide) |w| return fuzzyMasked(name, w, q, cap);
        var buf: [64]u8 = @splat(0);
        @memcpy(buf[0..name.len], name);
        return fuzzyMasked(name, &buf, q, cap);
    }
    return fuzzyScalar(name, q, cap);
}

pub fn fuzzyScore(name: []const u8, q: []const u8) ?i32 {
    return fuzzyScoreCapped(name, null, q, 100);
}

fn oneEditPrefix(w: []const u8, q: []const u8) ?usize {
    var diff: ?usize = null;
    for (0..q.len) |i| {
        if (i >= w.len or fmt.fold(w[i]) != q[i]) {
            diff = i;
            break;
        }
    }
    const i = diff orelse return null;
    if (std.ascii.isDigit(q[i]) or (i < w.len and std.ascii.isDigit(w[i]))) return null;
    const rest = q[i + 1 ..];
    const after = if (i + 1 <= w.len) w[i + 1 ..] else w[0..0];
    if (i + 1 < q.len and i + 1 < w.len and fmt.fold(w[i]) == q[i + 1] and fmt.fold(w[i + 1]) == q[i]) {
        if (w.len >= i + 2 + q[i + 2 ..].len and startsFold(w[i + 2 ..], q[i + 2 ..])) return q.len;
    }
    if (i < w.len and startsFold(after, rest)) return q.len;
    if (startsFold(w[i..], rest)) return q.len - 1;
    if (i < w.len and startsFold(after, q[i..])) return q.len + 1;
    return null;
}

fn startsFold(w: []const u8, q: []const u8) bool {
    if (w.len < q.len) return false;
    for (0..q.len) |i| {
        if (fmt.fold(w[i]) != q[i]) return false;
    }
    return true;
}

fn typoAt(name: []const u8, wide: ?*const [64]u8, s: usize, q: []const u8) ?i32 {
    if (s >= name.len or fmt.fold(name[s]) != q[0]) return null;
    const flen = oneEditPrefix(name[s..], q) orelse return null;
    var fixed: [128]u8 = undefined;
    if (flen > fixed.len or s + flen > name.len) return null;
    for (0..flen) |i| fixed[i] = fmt.fold(name[s + i]);
    const sc = fuzzyScoreCapped(name, wide, fixed[0..flen], 30) orelse return null;
    return sc - TYPO_COST;
}

fn typoScore(name: []const u8, wide: ?*const [64]u8, m: u64, q: []const u8) ?i32 {
    const off: usize = @intFromBool(name.len > 1 and name[0] == '.');
    var best = typoAt(name, wide, off, q);
    if ((m & fmt.charBit(' ')) != 0) {
        for (name, 0..) |b, sp| {
            if (b == ' ') {
                if (typoAt(name, wide, sp + 1, q)) |cand| {
                    best = if (best) |prev| @max(prev, cand) else cand;
                }
            }
        }
    }
    return best;
}

pub fn tokenScore(name: []const u8, wide: ?*const [64]u8, m: u64, t: *const Token) ?i32 {
    switch (t.mode) {
        .fuzzy => {
            if (takesTypos(t.text, t.mode)) {
                const clean = if ((t.mask & ~m) == 0) fuzzyScoreCapped(name, wide, t.text, 100) else null;
                const typo = if ((m & t.start) != 0) typoScore(name, wide, m, t.text) else null;
                if (clean) |c| {
                    return if (typo) |tp| @max(c, tp) else c;
                }
                return typo;
            }
            return fuzzyScoreCapped(name, wide, t.text, 100);
        },
        .exact => {
            const p = findCi(name, t.text) orelse return null;
            return 40 + (if (p == 0) @as(i32, 30) else 0) - lenPenalty(name.len);
        },
        .prefix => {
            if (name.len < t.text.len) return null;
            for (name[0..t.text.len], t.text) |a, b| {
                if (fmt.fold(a) != b) return null;
            }
            return 60 - lenPenalty(name.len);
        },
        .suffix => {
            if (name.len < t.text.len) return null;
            for (name[name.len - t.text.len ..], t.text) |a, b| {
                if (fmt.fold(a) != b) return null;
            }
            return 50 - lenPenalty(name.len);
        },
    }
}

pub fn tokenMatches(name: []const u8, t: *const Token) bool {
    return switch (t.mode) {
        .fuzzy => isSubseq(name, t.text),
        else => tokenScore(name, null, std.math.maxInt(u64), t) != null,
    };
}

pub fn maxBrokenTrigramBound(q: []const u8) i32 {
    if (q.len < 3) return std.math.maxInt(i32);
    const m: i32 = @intCast(q.len);
    const lp = @divTrunc(@min(m + 1, 80), 3);
    return 24 * m + 5 - lp;
}

pub fn maxTypoBound(q: []const u8) i32 {
    if (q.len < TYPO_MIN_LEN) return std.math.minInt(i32);
    const m: i32 = @intCast(q.len);
    const lp = @divTrunc(@min(m + 1, 80), 3);
    return 24 * m + 2 - lp;
}

pub fn maxCleanTokenBound(t: *const Token) i32 {
    const m: i32 = @intCast(t.text.len);
    return switch (t.mode) {
        .fuzzy => 24 * m + 108,
        .exact => 70,
        .prefix => 60,
        .suffix => 50,
    };
}

pub fn hasAllTrigrams(name: []const u8, q: []const u8) bool {
    if (q.len < 3) return true;
    if (name.len < 3) return false;
    for (0..q.len - 2) |qi| {
        const qt = fmt.trigramId(q[qi], q[qi + 1], q[qi + 2]);
        var found = false;
        for (0..name.len - 2) |ni| {
            if (fmt.trigramId(name[ni], name[ni + 1], name[ni + 2]) == qt) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}
