const std = @import("std");
const fmt = @import("index_fmt.zig");
const walk = @import("walk.zig");
const fuzzy = @import("fuzzy_simd.zig");

extern "c" fn realpath(path: [*:0]const u8, resolved: ?[*]u8) ?[*:0]u8;
extern "c" fn free(ptr: ?*anyopaque) void;
extern "c" fn time(t: ?*i64) i64;

pub const Mode = fuzzy.Mode;
pub const Token = fuzzy.Token;

pub fn nowSecs() u32 {
    const t = time(null);
    return if (t <= 0) 0 else @intCast(@min(t, std.math.maxInt(u32)));
}

const TypeGroup = struct {
    name: []const u8,
    exts: []const []const u8,
};

const type_groups = [_]TypeGroup{
    .{ .name = "image", .exts = &.{ "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "svg", "raw", "cr2", "cr3", "nef", "arw", "dng", "psd", "ico", "icns", "avif", "jxl" } },
    .{ .name = "video", .exts = &.{ "mp4", "mov", "m4v", "mkv", "avi", "webm", "wmv", "flv", "mpg", "mpeg", "3gp", "hevc" } },
    .{ .name = "audio", .exts = &.{ "mp3", "m4a", "aac", "wav", "flac", "aiff", "aif", "ogg", "opus", "alac", "caf", "mid", "midi", "m4r" } },
    .{ .name = "doc", .exts = &.{ "pdf", "doc", "docx", "pages", "txt", "md", "rtf", "odt", "key", "ppt", "pptx", "numbers", "xls", "xlsx", "csv", "epub", "tex" } },
    .{ .name = "code", .exts = &.{ "rs", "c", "h", "cc", "cpp", "hpp", "m", "mm", "swift", "go", "py", "js", "mjs", "cjs", "ts", "tsx", "jsx", "java", "kt", "rb", "php", "cs", "sh", "zsh", "bash", "fish", "lua", "sql", "html", "css", "scss", "json", "yaml", "yml", "toml", "xml", "vue", "svelte", "zig", "nim", "hs", "ml", "ex", "exs", "erl", "clj", "dart", "r", "jl", "metal", "glsl", "wgsl", "proto", "graphql", "nix" } },
    .{ .name = "archive", .exts = &.{ "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "pkg", "iso", "zst", "lz4", "xip" } },
    .{ .name = "font", .exts = &.{ "ttf", "otf", "woff", "woff2", "ttc", "dfont" } },
};

pub const Query = struct {
    tokens: std.ArrayList(Token) = .empty,
    kind: ?u8 = null,
    apps: bool = false,
    exts: std.ArrayList([]u8) = .empty,
    scope: ?[]u8 = null,
    size_min: u64 = 0,
    size_max: u64 = std.math.maxInt(u64),
    mtime_min: u32 = 0,
    mtime_max: u32 = std.math.maxInt(u32),
    limit: usize = 50,

    pub fn deinit(q: *Query, gpa: std.mem.Allocator) void {
        for (q.tokens.items) |t| gpa.free(t.text);
        q.tokens.deinit(gpa);
        for (q.exts.items) |e| gpa.free(e);
        q.exts.deinit(gpa);
        if (q.scope) |s| gpa.free(s);
    }

    pub fn parse(gpa: std.mem.Allocator, s: []const u8, home: []const u8) !Query {
        var q: Query = .{};
        errdefer q.deinit(gpa);
        var words: std.ArrayList([]u8) = .empty;
        defer {
            for (words.items) |w| gpa.free(w);
            words.deinit(gpa);
        }
        try splitWords(gpa, s, &words);
        for (words.items) |word| {
            if (std.mem.indexOfScalar(u8, word, ':')) |colon| {
                const k = word[0..colon];
                const v = word[colon + 1 ..];
                if (try q.filter(gpa, k, v, home)) continue;
            }
            var it = std.mem.tokenizeScalar(u8, word, '/');
            while (it.next()) |piece| {
                try q.pushToken(gpa, piece);
            }
        }
        return q;
    }

    pub fn pushToken(q: *Query, gpa: std.mem.Allocator, w: []const u8) !void {
        var t = w;
        var negate = false;
        var mode: Mode = .fuzzy;
        if (std.mem.startsWith(u8, t, "!")) {
            t = t[1..];
            negate = true;
            mode = .exact;
        }
        if (std.mem.startsWith(u8, t, "'")) {
            t = t[1..];
            mode = .exact;
        } else if (std.mem.startsWith(u8, t, "^")) {
            t = t[1..];
            mode = .prefix;
        } else if (std.mem.endsWith(u8, t, "$") and t.len > 0) {
            t = t[0 .. t.len - 1];
            mode = .suffix;
        }
        if (t.len == 0) return;
        if (!negate) {
            var pos_count: usize = 0;
            for (q.tokens.items) |tok| {
                if (!tok.negate) pos_count += 1;
            }
            if (pos_count >= 8) return;
        }
        const text = try gpa.alloc(u8, t.len);
        errdefer gpa.free(text);
        var mask: u64 = 0;
        for (t, 0..) |b, i| {
            const lb = std.ascii.toLower(b);
            text[i] = lb;
            mask |= fmt.charBit(lb);
        }
        const typos = fuzzy.takesTypos(text, mode);
        const loose: u64 = if (typos) mask & ~fmt.charBit(text[0]) else 0;
        const start: u64 = if (typos) fmt.startBit(text[0]) else 0;
        try q.tokens.append(gpa, .{
            .text = text,
            .mask = mask,
            .mode = mode,
            .negate = negate,
            .loose = loose,
            .start = start,
        });
    }

    pub fn filter(q: *Query, gpa: std.mem.Allocator, k: []const u8, v: []const u8, home: []const u8) !bool {
        if (std.mem.eql(u8, k, "ext")) {
            var it = std.mem.splitScalar(u8, v, ',');
            while (it.next()) |e| {
                const clean = std.mem.trimStart(u8, e, ".");
                if (clean.len == 0) continue;
                const lower = try gpa.alloc(u8, clean.len);
                for (clean, 0..) |b, i| lower[i] = std.ascii.toLower(b);
                try q.exts.append(gpa, lower);
            }
            return true;
        }
        if (std.mem.eql(u8, k, "type")) {
            var it = std.mem.splitScalar(u8, v, ',');
            while (it.next()) |t| {
                if (std.mem.eql(u8, t, "app")) {
                    q.kind = walk.KIND_DIR;
                    q.apps = true;
                    try q.exts.append(gpa, try gpa.dupe(u8, "app"));
                    continue;
                }
                var found = false;
                for (type_groups) |g| {
                    if (std.mem.eql(u8, g.name, t)) {
                        for (g.exts) |e| try q.exts.append(gpa, try gpa.dupe(u8, e));
                        found = true;
                        break;
                    }
                }
                if (!found) return error.UnknownType;
            }
            return true;
        }
        if (std.mem.eql(u8, k, "kind")) {
            if (std.mem.eql(u8, v, "file") or std.mem.eql(u8, v, "f")) {
                q.kind = walk.KIND_FILE;
            } else if (std.mem.eql(u8, v, "dir") or std.mem.eql(u8, v, "folder") or std.mem.eql(u8, v, "d")) {
                q.kind = walk.KIND_DIR;
            } else if (std.mem.eql(u8, v, "link") or std.mem.eql(u8, v, "symlink") or std.mem.eql(u8, v, "l")) {
                q.kind = walk.KIND_LINK;
            } else return error.UnknownKind;
            return true;
        }
        if (std.mem.eql(u8, k, "in")) {
            const expanded = if (std.mem.startsWith(u8, v, "~"))
                try std.fmt.allocPrint(gpa, "{s}{s}", .{ home, v[1..] })
            else
                try gpa.dupe(u8, v);
            defer gpa.free(expanded);
            const resolved = try resolveScope(gpa, expanded);
            if (q.scope) |old| gpa.free(old);
            q.scope = resolved;
            return true;
        }
        if (std.mem.eql(u8, k, "size")) {
            const r = try parseRange(v, parseSize);
            q.size_min = r[0];
            q.size_max = r[1];
            return true;
        }
        if (std.mem.eql(u8, k, "mtime") or std.mem.eql(u8, k, "modified")) {
            const now = nowSecs();
            const r = try parseRange(v, parseAge);
            const lo = r[0];
            const hi = r[1];
            q.mtime_min = if (hi == std.math.maxInt(u64)) 0 else now -| @as(u32, @intCast(@min(hi, now)));
            q.mtime_max = now -| @as(u32, @intCast(@min(lo, now)));
            return true;
        }
        if (std.mem.eql(u8, k, "limit")) {
            q.limit = std.fmt.parseInt(usize, v, 10) catch return error.BadLimit;
            return true;
        }
        return false;
    }

    pub inline fn kindOk(q: *const Query, k: u8) bool {
        const want = q.kind orelse return true;
        const base = k & 3;
        return base == want or (q.apps and base == walk.KIND_LINK);
    }

    pub fn extOk(name: []const u8, exts: []const []const u8) bool {
        const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
        const e = name[dot + 1 ..];
        for (exts) |want| {
            if (fuzzy.eqFold(e, want)) return true;
        }
        return false;
    }

    pub fn matchPath(q: *const Query, path: []const u8, kind_val: u8, sz: u64, mtime: u32) ?i32 {
        if (q.scope) |s| {
            if (s.len > 1) {
                if (!std.mem.startsWith(u8, path, s) or path.len <= s.len or path[s.len] != '/') return null;
            }
        }
        const cut = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
        const name = if (cut + 1 <= path.len) path[cut + 1 ..] else path[0..0];
        if (name.len == 0 or !q.kindOk(kind_val)) return null;
        if (q.exts.items.len > 0 and !extOk(name, q.exts.items)) return null;
        if (sz < q.size_min or sz > q.size_max or mtime < q.mtime_min or mtime > q.mtime_max) return null;

        var pos_count: usize = 0;
        for (q.tokens.items) |tok| {
            if (!tok.negate) pos_count += 1;
        }
        if (pos_count == 0) {
            for (q.tokens.items) |*tok| {
                if (tok.negate and dirNegated(path, tok)) return null;
            }
            return 0;
        }
        const m = fmt.nameMask(name);
        var any_name = false;
        for (q.tokens.items) |*tok| {
            if (!tok.negate and tok.fits(m) and fuzzy.tokenScore(name, null, m, tok) != null) {
                any_name = true;
                break;
            }
        }
        if (!any_name) return null;
        for (q.tokens.items) |*tok| {
            if (tok.negate and fuzzy.tokenMatches(name, tok)) return null;
        }
        const dir_slice = path[0..cut];
        for (q.tokens.items) |*tok| {
            if (tok.negate and dirNegated(dir_slice, tok)) return null;
        }
        var score: i32 = 0;
        var pos_i: usize = 0;
        for (q.tokens.items) |*tok| {
            if (tok.negate) continue;
            if (tok.fits(m)) {
                if (fuzzy.tokenScore(name, null, m, tok)) |s| {
                    score += s;
                    pos_i += 1;
                    continue;
                }
            }
            var best_dir: ?i32 = null;
            var dit = std.mem.tokenizeScalar(u8, dir_slice, '/');
            while (dit.next()) |comp| {
                if (fuzzy.tokenScore(comp, null, std.math.maxInt(u64), tok)) |ds| {
                    best_dir = if (best_dir) |prev| @max(prev, ds) else ds;
                }
            }
            const ds = best_dir orelse return null;
            score += @divTrunc(ds * 3, 4);
            pos_i += 1;
        }
        return score;
    }
};

fn dirNegated(dir_slice: []const u8, tok: *const Token) bool {
    var it = std.mem.tokenizeScalar(u8, dir_slice, '/');
    while (it.next()) |comp| {
        if (fuzzy.tokenMatches(comp, tok)) return true;
    }
    return false;
}

fn resolveScope(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const pz = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(pz);
    if (realpath(pz, null)) |rp| {
        defer free(rp);
        const s = std.mem.span(rp);
        const trimmed = if (s.len > 1) std.mem.trimEnd(u8, s, "/") else s;
        return try gpa.dupe(u8, trimmed);
    }
    const trimmed = if (path.len > 1) std.mem.trimEnd(u8, path, "/") else path;
    return try gpa.dupe(u8, trimmed);
}

fn splitWords(gpa: std.mem.Allocator, s: []const u8, out: *std.ArrayList([]u8)) !void {
    var cur: std.ArrayList(u8) = .empty;
    defer cur.deinit(gpa);
    var quoted = false;
    for (s) |c| {
        if (c == '"') {
            quoted = !quoted;
        } else if (c == ' ' and !quoted) {
            if (cur.items.len > 0) {
                try out.append(gpa, try cur.toOwnedSlice(gpa));
            }
        } else {
            try cur.append(gpa, c);
        }
    }
    if (cur.items.len > 0) {
        try out.append(gpa, try cur.toOwnedSlice(gpa));
    }
}

fn parseRange(v: []const u8, p: *const fn ([]const u8) ?u64) ![2]u64 {
    if (std.mem.startsWith(u8, v, ">=")) return .{ p(v[2..]) orelse return error.BadRange, std.math.maxInt(u64) };
    if (std.mem.startsWith(u8, v, ">")) return .{ p(v[1..]) orelse return error.BadRange, std.math.maxInt(u64) };
    if (std.mem.startsWith(u8, v, "<=")) return .{ 0, p(v[2..]) orelse return error.BadRange };
    if (std.mem.startsWith(u8, v, "<")) return .{ 0, p(v[1..]) orelse return error.BadRange };
    if (std.mem.indexOf(u8, v, "..")) |idx| {
        const a = p(v[0..idx]) orelse return error.BadRange;
        const b = p(v[idx + 2 ..]) orelse return error.BadRange;
        return .{ a, b };
    }
    const x = p(v) orelse return error.BadRange;
    return .{ x, x };
}

fn parseSize(s: []const u8) ?u64 {
    var i: usize = 0;
    while (i < s.len and (std.ascii.isDigit(s[i]) or s[i] == '.')) : (i += 1) {}
    if (i == 0) return null;
    const n = std.fmt.parseFloat(f64, s[0..i]) catch return null;
    const unit = s[i..];
    const mult: f64 = if (unit.len == 0 or std.ascii.eqlIgnoreCase(unit, "b"))
        1.0
    else if (std.ascii.eqlIgnoreCase(unit, "k") or std.ascii.eqlIgnoreCase(unit, "kb"))
        1e3
    else if (std.ascii.eqlIgnoreCase(unit, "m") or std.ascii.eqlIgnoreCase(unit, "mb"))
        1e6
    else if (std.ascii.eqlIgnoreCase(unit, "g") or std.ascii.eqlIgnoreCase(unit, "gb"))
        1e9
    else if (std.ascii.eqlIgnoreCase(unit, "t") or std.ascii.eqlIgnoreCase(unit, "tb"))
        1e12
    else
        return null;
    return @intFromFloat(n * mult);
}

fn parseAge(s: []const u8) ?u64 {
    var i: usize = 0;
    while (i < s.len and (std.ascii.isDigit(s[i]) or s[i] == '.')) : (i += 1) {}
    if (i == 0) return null;
    const n = std.fmt.parseFloat(f64, s[0..i]) catch return null;
    const unit = s[i..];
    const mult: f64 = if (std.ascii.eqlIgnoreCase(unit, "s"))
        1.0
    else if (std.ascii.eqlIgnoreCase(unit, "m") or std.ascii.eqlIgnoreCase(unit, "min"))
        60.0
    else if (std.ascii.eqlIgnoreCase(unit, "h"))
        3600.0
    else if (unit.len == 0 or std.ascii.eqlIgnoreCase(unit, "d"))
        86400.0
    else if (std.ascii.eqlIgnoreCase(unit, "w"))
        604800.0
    else if (std.ascii.eqlIgnoreCase(unit, "mo"))
        2592000.0
    else if (std.ascii.eqlIgnoreCase(unit, "y"))
        31536000.0
    else
        return null;
    return @intFromFloat(n * mult);
}
