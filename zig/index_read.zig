const std = @import("std");
const fmt = @import("index_fmt.zig");
const walk = @import("walk.zig");

extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;

pub const FolderTotal = struct {
    name: []const u8,
    totals: fmt.Totals,
};

pub const Index = struct {
    map: []align(std.heap.page_size_min) const u8,
    n: usize,
    d: usize,
    u: usize,
    names_len: usize,
    nbig: usize,
    ntri_posts: usize,
    nhead_posts: usize,
    nby_key: usize,
    nmarked: usize,
    words: usize,
    zones_len: usize,
    event_id: u64,
    synced_at: u32,
    by_key_cover: i32,
    top_prior: i8,
    off: [fmt.NZSEC]usize,

    pub fn savedEventId(path: []const u8) ?u64 {
        var pbuf: [2048]u8 = undefined;
        const cpath = std.fmt.bufPrintSentinel(&pbuf, "{s}", .{path}, 0) catch return null;
        const fd = open(cpath, 0);
        if (fd < 0) return null;
        defer _ = close(fd);
        var hdr: [128]u8 = undefined;
        const got = read(fd, &hdr, hdr.len);
        if (got < 128) return null;
        const f = fmt.readHeaderFields(13, &hdr, fmt.MAGIC_ZSIDX) orelse return null;
        return f[4];
    }

    pub fn load(path: []const u8) !Index {
        const map = try fmt.mmapFile(path);
        errdefer fmt.unmapFile(map);
        if (map.len < fmt.HDR) return error.InvalidIndex;
        const f = fmt.readHeaderFields(13, map, fmt.MAGIC_ZSIDX) orelse return error.InvalidMagic;
        const n: usize = @intCast(f[0]);
        const d: usize = @intCast(f[1]);
        const u: usize = @intCast(f[2]);
        const names_len: usize = @intCast(f[3]);
        const event_id = f[4];
        const synced_at: u32 = @intCast(f[5]);
        const nbig: usize = @intCast(f[6]);
        const ntri_posts: usize = @intCast(f[7]);
        const nhead_posts: usize = @intCast(f[8]);
        const nby_key: usize = @intCast(f[9]);
        const cover_i64: i64 = @bitCast(f[10]);
        const by_key_cover: i32 = @intCast(cover_i64);
        const top_prior_u8: u8 = @intCast(f[11] & 0xFF);
        const top_prior: i8 = @bitCast(top_prior_u8);
        const nmarked: usize = @intCast(f[12]);

        const lay = fmt.computeLayout(fmt.NZSEC, fmt.zsectionLens(
            n,
            d,
            u,
            names_len,
            nbig,
            ntri_posts,
            nhead_posts,
            nby_key,
            nmarked,
        ));
        if (map.len < lay.total) return error.TruncatedIndex;
        return .{
            .map = map,
            .n = n,
            .d = d,
            .u = u,
            .names_len = names_len,
            .nbig = nbig,
            .ntri_posts = ntri_posts,
            .nhead_posts = nhead_posts,
            .nby_key = nby_key,
            .nmarked = nmarked,
            .words = std.math.divCeil(usize, u, 64) catch unreachable,
            .zones_len = std.math.divCeil(usize, n, fmt.ZONE) catch unreachable,
            .event_id = event_id,
            .synced_at = synced_at,
            .by_key_cover = by_key_cover,
            .top_prior = top_prior,
            .off = lay.off,
        };
    }

    pub fn deinit(self: *Index) void {
        fmt.unmapFile(self.map);
    }

    pub fn bytes(self: *const Index) usize {
        return self.map.len;
    }

    fn slice(self: *const Index, comptime T: type, sec: fmt.ZSec, count: usize) []const T {
        const ptr: [*]const T = @ptrCast(@alignCast(self.map.ptr + self.off[@backingInt(sec)]));
        return ptr[0..count];
    }

    pub fn trigramOff(self: *const Index) []const u32 {
        return self.slice(u32, .trigram_off, fmt.TRIGRAM_BUCKETS + 1);
    }

    pub fn trigramPosts(self: *const Index) []const u32 {
        return self.slice(u32, .trigram_posts, self.ntri_posts);
    }

    pub fn trigramSlice(self: *const Index, tri: u32) []const u32 {
        const o = self.trigramOff();
        return self.trigramPosts()[o[tri]..o[tri + 1]];
    }

    pub fn headOff(self: *const Index) []const u32 {
        return self.slice(u32, .head_off, fmt.HEAD_BUCKETS + 1);
    }

    pub fn headPosts(self: *const Index) []const u32 {
        return self.slice(u32, .head_posts, self.nhead_posts);
    }

    pub fn headSlice(self: *const Index, cls: u6) []const u32 {
        const o = self.headOff();
        return self.headPosts()[o[cls]..o[@as(usize, cls) + 1]];
    }

    pub fn byKey(self: *const Index) []const u32 {
        return self.slice(u32, .by_key, self.nby_key);
    }

    pub fn byKeyCounts(self: *const Index) []const u32 {
        return self.slice(u32, .by_key_counts, 256);
    }

    pub fn nameBits(self: *const Index) []const u64 {
        return self.slice(u64, .name_bits, self.words * fmt.NBITMAPS);
    }

    pub fn bitmap(self: *const Index, b: usize) []const u64 {
        return self.nameBits()[b * self.words ..][0..self.words];
    }

    pub fn classCounts(self: *const Index) []const u32 {
        return self.slice(u32, .class_counts, fmt.CLASSES * 2)[0..fmt.CLASSES];
    }

    pub fn doubleCounts(self: *const Index) []const u32 {
        return self.slice(u32, .class_counts, fmt.CLASSES * 2)[fmt.CLASSES .. fmt.CLASSES * 2];
    }

    pub fn nameOff(self: *const Index) []const u32 {
        return self.slice(u32, .name_off, self.u + 1);
    }

    pub fn names(self: *const Index) []const u8 {
        return self.slice(u8, .names, self.names_len + 64);
    }

    pub fn nameInfo(self: *const Index) []const fmt.NameInfo {
        return self.slice(fmt.NameInfo, .name_info, self.u);
    }

    pub fn namePrior(self: *const Index) []const i8 {
        return self.slice(i8, .name_prior, self.u);
    }

    pub fn nameExt(self: *const Index) []const u8 {
        return self.slice(u8, .name_ext, self.u);
    }

    pub fn extTable(self: *const Index) []const [16]u8 {
        return self.slice([16]u8, .exts, 256);
    }

    pub fn extSlot(self: *const Index, e: []const u8) u8 {
        const t = self.extTable();
        for (1..255) |i| {
            if (t[i][0] == e.len and std.mem.eql(u8, t[i][1 .. 1 + e.len], e)) {
                return @intCast(i);
            }
        }
        return 255;
    }

    pub fn nameEntsOff(self: *const Index) []const u32 {
        return self.slice(u32, .name_ents_off, self.u + 1);
    }

    pub fn nameEnts(self: *const Index) []const u32 {
        return self.slice(u32, .name_ents, self.n);
    }

    pub fn entName(self: *const Index) []const u32 {
        return self.slice(u32, .ent_name, self.n);
    }

    pub fn kind(self: *const Index) []const u8 {
        return self.slice(u8, .kind, self.n);
    }

    pub fn parent(self: *const Index) []const u32 {
        return self.slice(u32, .parent, self.n);
    }

    pub fn sizeRaw(self: *const Index) []const u32 {
        return self.slice(u32, .size, self.n);
    }

    pub fn allocRaw(self: *const Index) []const u32 {
        return self.slice(u32, .alloc, self.n);
    }

    pub fn mtime(self: *const Index) []const u32 {
        return self.slice(u32, .mtime, self.n);
    }

    pub fn dirEntry(self: *const Index) []const u32 {
        return self.slice(u32, .dir_entry, self.d);
    }

    pub fn dirStart(self: *const Index) []const u32 {
        return self.slice(u32, .dir_start, self.d);
    }

    pub fn dirLen(self: *const Index) []const u32 {
        return self.slice(u32, .dir_len, self.d);
    }

    pub fn dirEnd(self: *const Index) []const u32 {
        return self.slice(u32, .dir_end, self.d);
    }

    pub fn dirPrior(self: *const Index) []const i8 {
        return self.slice(i8, .dir_prior, self.d);
    }

    pub fn dirParent(self: *const Index) []const u32 {
        return self.slice(u32, .dir_parent, self.d);
    }

    pub fn dirBytes(self: *const Index) []const u64 {
        return self.slice(u64, .dir_bytes, self.d);
    }

    pub fn dirAlloc(self: *const Index) []const u64 {
        return self.slice(u64, .dir_alloc, self.d);
    }

    pub fn zones(self: *const Index) []const fmt.Zone {
        return self.slice(fmt.Zone, .zones, self.zones_len);
    }

    pub fn big(self: *const Index) []const u64 {
        return self.slice(u64, .big, self.nbig);
    }

    pub fn marked(self: *const Index) []const u32 {
        return self.slice(u32, .marked, self.nmarked);
    }

    pub inline fn uname(self: *const Index, id: u32) []const u8 {
        const o = self.nameOff();
        return self.names()[o[id]..o[id + 1]];
    }

    pub inline fn unameWide(self: *const Index, id: u32) ?*const [64]u8 {
        const o = self.nameOff();
        const a = o[id];
        const b = o[id + 1];
        if (b - a > 64) return null;
        return @ptrCast(self.names().ptr + a);
    }

    pub inline fn name(self: *const Index, entry_idx: usize) []const u8 {
        return self.uname(self.entName()[entry_idx]);
    }

    pub inline fn sizeOf(self: *const Index, entry_idx: usize) u64 {
        return fmt.unpackSize(self.sizeRaw()[entry_idx], 1, self.big());
    }

    pub inline fn allocOf(self: *const Index, entry_idx: usize) u64 {
        return fmt.unpackSize(self.allocRaw()[entry_idx], fmt.ALLOC_UNIT, self.big());
    }

    pub fn dirOf(self: *const Index, entry: u32) ?u32 {
        const de = self.dirEntry();
        var lo: usize = 0;
        var hi: usize = de.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (de[mid] < entry) lo = mid + 1 else if (de[mid] > entry) hi = mid else return @intCast(mid);
        }
        return null;
    }

    pub fn children(self: *const Index, d: u32) struct { start: usize, end: usize } {
        const s = self.dirStart()[d];
        const l = self.dirLen()[d];
        return .{ .start = s, .end = s + l };
    }

    pub fn descendants(self: *const Index, k: u32) struct { start: u32, end: u32 } {
        const de = self.dirEntry();
        const s = self.dirStart()[k];
        const e = self.dirEnd()[k];
        return .{
            .start = lowerBound(de, s),
            .end = lowerBound(de, e),
        };
    }

    pub fn pathInto(self: *const Index, i: usize, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
        out.clearRetainingCapacity();
        if (i == 0) {
            try out.append(gpa, '/');
            return;
        }
        const de = self.dirEntry();
        const dp = self.dirParent();
        const par = self.parent();
        var chain: [256]u32 = undefined;
        chain[0] = @intCast(i);
        var k: usize = 1;
        var d = par[i];
        while (d != 0 and k < chain.len) {
            chain[k] = de[d];
            k += 1;
            d = dp[d];
        }
        var j = k;
        while (j > 0) {
            j -= 1;
            try out.append(gpa, '/');
            try out.appendSlice(gpa, self.name(chain[j]));
        }
    }

    pub fn pathBuf(self: *const Index, i: usize, buf: []u8) ?[]const u8 {
        if (i == 0) {
            if (buf.len < 1) return null;
            buf[0] = '/';
            return buf[0..1];
        }
        const de = self.dirEntry();
        const dp = self.dirParent();
        const par = self.parent();
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
            const nm = self.name(chain[j]);
            if (len + 1 + nm.len > buf.len) return null;
            buf[len] = '/';
            len += 1;
            @memcpy(buf[len .. len + nm.len], nm);
            len += nm.len;
        }
        return buf[0..len];
    }

    pub fn lookup(self: *const Index, path: []const u8) ?u32 {
        var e: u32 = 0;
        var it = std.mem.tokenizeScalar(u8, path, '/');
        while (it.next()) |comp| {
            const d = self.dirOf(e) orelse return null;
            const r = self.children(d);
            var lo: usize = r.start;
            var hi: usize = r.end;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (std.mem.order(u8, self.name(mid), comp) == .lt) lo = mid + 1 else hi = mid;
            }
            if (lo < r.end and std.mem.eql(u8, self.name(lo), comp)) {
                e = @intCast(lo);
            } else {
                var found: ?u32 = null;
                for (r.start..r.end) |c| {
                    if (std.ascii.eqlIgnoreCase(self.name(c), comp)) {
                        found = @intCast(c);
                        break;
                    }
                }
                e = found orelse return null;
            }
        }
        return e;
    }

    pub fn totals(self: *const Index, path: []const u8) ?fmt.Totals {
        const clean = trimTrailingSlash(path);
        const e = self.lookup(clean) orelse return null;
        const d = self.dirOf(e) orelse return null;
        return self.dirTotals(d);
    }

    pub fn dirTotals(self: *const Index, d: u32) fmt.Totals {
        const s = self.dirStart()[d];
        const e = self.dirEnd()[d];
        const r = self.children(d);
        var vis: u64 = 0;
        for (r.start..r.end) |c| {
            const nm = self.name(c);
            const k = self.kind()[c];
            if (nm.len > 0 and nm[0] != '.' and (k & walk.FLAG_HIDDEN) == 0) vis += 1;
        }
        return .{
            .bytes = self.dirBytes()[d],
            .allocated = self.dirAlloc()[d],
            .items = e - s,
            .visible = vis,
            .hardlinks = 0,
        };
    }

    pub fn folderTotals(self: *const Index, dir_path: []const u8, gpa: std.mem.Allocator) !?[]FolderTotal {
        const clean = trimTrailingSlash(dir_path);
        const e = self.lookup(clean) orelse return null;
        const d = self.dirOf(e) orelse return null;
        const r = self.children(d);
        var out: std.ArrayList(FolderTotal) = .empty;
        errdefer out.deinit(gpa);
        for (r.start..r.end) |c| {
            const cd = self.dirOf(@intCast(c)) orelse continue;
            try out.append(gpa, .{
                .name = self.name(c),
                .totals = self.dirTotals(cd),
            });
        }
        return try out.toOwnedSlice(gpa);
    }
};

pub fn trimTrailingSlash(path: []const u8) []const u8 {
    if (path.len <= 1) return path;
    return std.mem.trimEnd(u8, path, "/");
}

fn lowerBound(slice: []const u32, target: u32) u32 {
    var lo: usize = 0;
    var hi: usize = slice.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (slice[mid] < target) lo = mid + 1 else hi = mid;
    }
    return @intCast(lo);
}
