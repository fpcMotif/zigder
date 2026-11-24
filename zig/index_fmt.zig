const std = @import("std");
const walk = @import("walk.zig");

extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn lseek(fd: c_int, offset: i64, whence: c_int) i64;

pub const MAGIC_ZSIDX: *const [8]u8 = "ZSIDX001";
pub const MAGIC_FSIDX: *const [8]u8 = "FSIDX012";
pub const HDR: usize = 4096;

pub const CLASSES: usize = 41;
pub const TRIGRAM_ALPHA: usize = 40;
pub const TRIGRAM_BUCKETS: usize = 64_000;
pub const HEAD_BUCKETS: usize = 41;
pub const BM_FIRST: usize = 0;
pub const BM_SECOND: usize = CLASSES;
pub const BM_START: usize = 2 * CLASSES;
pub const BM_DOT: usize = BM_START + 23;
pub const BM_APP: usize = BM_DOT + 1;
pub const BM_DOUBLE: usize = BM_APP + 1;
pub const NBITMAPS: usize = BM_DOUBLE + CLASSES;
pub const ZONE: usize = 1024;
pub const BIG_FLAG: u32 = @as(u32, 1) << 31;
pub const ALLOC_UNIT: u64 = 4096;
pub const SHORT_LEN: usize = 3;
pub const BY_KEY_WANT: usize = 1 << 14;

pub const NameInfo = extern struct {
    key: i8,
    len: u8,
    stem: u8,
    head: u8,
};

pub const Zone = extern struct {
    max_size: u64,
    min_mtime: u32,
    max_mtime: u32,
    kinds: u32,
};

comptime {
    if (@sizeOf(NameInfo) != 4) @compileError("NameInfo size mismatch");
    if (@sizeOf(Zone) != 24) @compileError("Zone size mismatch");
}

pub const ZSec = enum(usize) {
    trigram_off,
    trigram_posts,
    head_off,
    head_posts,
    by_key,
    by_key_counts,
    name_bits,
    class_counts,
    name_off,
    names,
    name_info,
    name_prior,
    name_ext,
    exts,
    name_ents_off,
    name_ents,
    ent_name,
    kind,
    parent,
    size,
    alloc,
    mtime,
    dir_entry,
    dir_start,
    dir_len,
    dir_end,
    dir_prior,
    dir_parent,
    dir_bytes,
    dir_alloc,
    zones,
    big,
    marked,
};

pub const NZSEC = @typeInfo(ZSec).@"enum".field_names.len;

pub const FSec = enum(usize) {
    name_bits,
    name_off,
    names,
    ent_name,
    kind,
    parent,
    size,
    alloc,
    mtime,
    dir_entry,
    dir_start,
    dir_len,
    dir_end,
    dir_prior,
    dir_parent,
    dir_bytes,
    dir_alloc,
    name_ents_off,
    name_ents,
    name_prior,
    name_info,
    name_ext,
    exts,
    zones,
    big,
};

pub const NFSEC = @typeInfo(FSec).@"enum".field_names.len;

pub fn align64(v: usize) usize {
    return (v + 63) & ~@as(usize, 63);
}

pub fn Layout(comptime N: usize) type {
    return struct {
        off: [N]usize,
        total: usize,
    };
}

pub fn computeLayout(comptime N: usize, lens: [N]usize) Layout(N) {
    var off: [N]usize = undefined;
    var at: usize = HDR;
    for (lens, 0..) |l, i| {
        off[i] = at;
        at = align64(at + l);
    }
    return .{ .off = off, .total = at };
}

pub fn zsectionLens(
    n: usize,
    d: usize,
    u: usize,
    names_len: usize,
    nbig: usize,
    ntri_posts: usize,
    nhead_posts: usize,
    nby_key: usize,
    nmarked: usize,
) [NZSEC]usize {
    const words = std.math.divCeil(usize, u, 64) catch unreachable;
    const zlen = std.math.divCeil(usize, n, ZONE) catch unreachable;
    const padded_names = names_len + 64;
    return .{
        (TRIGRAM_BUCKETS + 1) * 4,
        ntri_posts * 4,
        (HEAD_BUCKETS + 1) * 4,
        nhead_posts * 4,
        nby_key * 4,
        256 * 4,
        words * NBITMAPS * 8,
        CLASSES * 2 * 4,
        (u + 1) * 4,
        padded_names,
        u * @sizeOf(NameInfo),
        u,
        u,
        256 * 16,
        (u + 1) * 4,
        n * 4,
        n * 4,
        n,
        n * 4,
        n * 4,
        n * 4,
        n * 4,
        d * 4,
        d * 4,
        d * 4,
        d * 4,
        d,
        d * 4,
        d * 8,
        d * 8,
        zlen * @sizeOf(Zone),
        nbig * 8,
        nmarked * 4,
    };
}

pub fn fsectionLens(n: usize, d: usize, u: usize, names_len: usize, nbig: usize) [NFSEC]usize {
    const words = std.math.divCeil(usize, u, 64) catch unreachable;
    const zlen = std.math.divCeil(usize, n, ZONE) catch unreachable;
    return .{
        words * NBITMAPS * 8,
        (u + 1) * 4,
        names_len,
        n * 4,
        n,
        n * 4,
        n * 4,
        n * 4,
        n * 4,
        d * 4,
        d * 4,
        d * 4,
        d * 4,
        d,
        d * 4,
        d * 8,
        d * 8,
        (u + 1) * 4,
        n * 4,
        u,
        u * @sizeOf(NameInfo),
        u,
        256 * 16,
        zlen * @sizeOf(Zone),
        nbig * 8,
    };
}

pub inline fn fold(b: u8) u8 {
    return b | (@as(u8, @intFromBool((b -% 'A') < 26)) << 5);
}

pub inline fn charClass(b: u8) u6 {
    return switch (b) {
        'a'...'z' => @intCast(b - 'a'),
        'A'...'Z' => @intCast(b - 'A'),
        '0'...'9' => @intCast(26 + b - '0'),
        '.' => 36,
        '-', '_' => 37,
        ' ' => 38,
        0x80...0xFF => 39,
        else => 40,
    };
}

pub inline fn charBit(b: u8) u64 {
    return @as(u64, 1) << charClass(b);
}

pub inline fn trigramClass(b: u8) u32 {
    return switch (b) {
        'a'...'z' => b - 'a',
        'A'...'Z' => b - 'A',
        '0'...'9' => 26 + b - '0',
        '.' => 36,
        '-', '_' => 37,
        ' ' => 38,
        else => 39,
    };
}

pub inline fn trigramId(a: u8, b: u8, c: u8) u32 {
    return trigramClass(a) * 1600 + trigramClass(b) * 40 + trigramClass(c);
}

pub inline fn startHash(b: u8) usize {
    return @intCast(fold(b) % 23);
}

pub inline fn startBit(b: u8) u64 {
    return @as(u64, 1) << @intCast(CLASSES + startHash(b));
}

pub fn charMask(s: []const u8) u64 {
    var m: u64 = 0;
    for (s) |b| m |= charBit(b);
    return m;
}

pub fn nameMask(s: []const u8) u64 {
    const off: usize = @intFromBool(s.len > 1 and s[0] == '.');
    var m = charMask(s);
    if (off < s.len) m |= startBit(s[off]);
    if (s.len >= 2) {
        for (0..s.len - 1) |i| {
            if (s[i] == ' ') m |= startBit(s[i + 1]);
        }
    }
    return m;
}

pub fn doubledMask(s: []const u8) u64 {
    var once: u64 = 0;
    var twice: u64 = 0;
    for (s) |b| {
        const bit = charBit(b);
        twice |= once & bit;
        once |= bit;
    }
    return twice;
}

pub fn nameInfoOf(name: []const u8, prior: i8) NameInfo {
    const off: usize = @intFromBool(name.len > 1 and name[0] == '.');
    var stem: usize = name.len;
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |p| {
        if (p > off) stem = p;
    }
    var tweak: i32 = 10;
    if (std.mem.endsWith(u8, name, ".app")) tweak += 25;
    if (name.len > 0 and name[0] == '.') tweak -= 8;
    const len_pen: i32 = @divTrunc(@min(@as(i32, @intCast(name.len)), 80), 3);
    const raw_key = @as(i32, prior) + tweak - len_pen;
    const key: i8 = @intCast(std.math.clamp(raw_key, std.math.minInt(i8), std.math.maxInt(i8)));
    return .{
        .key = key,
        .len = @intCast(@min(name.len - off, 255)),
        .stem = @intCast(@min(stem - off, 255)),
        .head = if (off < name.len) fold(name[off]) else 0,
    };
}

pub inline fn unpackSize(v: u32, unit: u64, big: []const u64) u64 {
    if ((v & BIG_FLAG) == 0) return @as(u64, v) * unit;
    return big[v & ~BIG_FLAG];
}

pub const Totals = struct {
    bytes: u64 = 0,
    allocated: u64 = 0,
    items: u64 = 0,
    visible: u64 = 0,
    hardlinks: u64 = 0,
};

pub fn readHeaderFields(comptime N: usize, bytes: []const u8, magic: *const [8]u8) ?[N]u64 {
    if (bytes.len < 8 + N * 8) return null;
    if (!std.mem.eql(u8, bytes[0..8], magic)) return null;
    var out: [N]u64 = undefined;
    for (0..N) |i| {
        out[i] = std.mem.readInt(u64, bytes[8 + i * 8 ..][0..8], .little);
    }
    return out;
}

pub fn mmapFile(path: []const u8) ![]align(std.heap.page_size_min) const u8 {
    var path_buf: [2048]u8 = undefined;
    const cpath = try std.fmt.bufPrintSentinel(&path_buf, "{s}", .{path}, 0);
    const fd = open(cpath, 0);
    if (fd < 0) return error.OpenFailed;
    defer _ = close(fd);
    const end = lseek(fd, 0, 2);
    if (end <= 0) return error.EmptyFile;
    const len: usize = @intCast(end);
    return try std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .SHARED }, fd, 0);
}

pub fn unmapFile(mem: []align(std.heap.page_size_min) const u8) void {
    std.posix.munmap(mem);
}

pub const FounderIndex = struct {
    map: []align(std.heap.page_size_min) const u8,
    n: usize,
    d: usize,
    u: usize,
    names_len: usize,
    words: usize,
    zones_len: usize,
    event_id: u64,
    synced_at: u32,
    nbig: usize,
    off: [NFSEC]usize,

    pub fn load(path: []const u8) !FounderIndex {
        const map = try mmapFile(path);
        errdefer unmapFile(map);
        if (map.len < HDR) return error.InvalidIndex;
        const f = readHeaderFields(7, map, MAGIC_FSIDX) orelse return error.InvalidMagic;
        const n: usize = @intCast(f[0]);
        const d: usize = @intCast(f[1]);
        const u: usize = @intCast(f[2]);
        const names_len: usize = @intCast(f[3]);
        const event_id = f[4];
        const synced_at: u32 = @intCast(f[5]);
        const nbig: usize = @intCast(f[6]);
        const lay = computeLayout(NFSEC, fsectionLens(n, d, u, names_len, nbig));
        if (map.len < lay.total) return error.TruncatedIndex;
        return .{
            .map = map,
            .n = n,
            .d = d,
            .u = u,
            .names_len = names_len,
            .words = std.math.divCeil(usize, u, 64) catch unreachable,
            .zones_len = std.math.divCeil(usize, n, ZONE) catch unreachable,
            .event_id = event_id,
            .synced_at = synced_at,
            .nbig = nbig,
            .off = lay.off,
        };
    }

    pub fn deinit(self: *FounderIndex) void {
        unmapFile(self.map);
    }

    pub fn slice(self: *const FounderIndex, comptime T: type, sec: FSec, count: usize) []const T {
        const ptr: [*]const T = @ptrCast(@alignCast(self.map.ptr + self.off[@backingInt(sec)]));
        return ptr[0..count];
    }

    pub fn nameBits(self: *const FounderIndex) []const u64 {
        return self.slice(u64, .name_bits, self.words * NBITMAPS);
    }

    pub fn bitmap(self: *const FounderIndex, b: usize) []const u64 {
        return self.nameBits()[b * self.words ..][0..self.words];
    }

    pub fn nameOff(self: *const FounderIndex) []const u32 {
        return self.slice(u32, .name_off, self.u + 1);
    }

    pub fn names(self: *const FounderIndex) []const u8 {
        return self.slice(u8, .names, self.names_len);
    }

    pub fn entName(self: *const FounderIndex) []const u32 {
        return self.slice(u32, .ent_name, self.n);
    }

    pub fn kind(self: *const FounderIndex) []const u8 {
        return self.slice(u8, .kind, self.n);
    }

    pub fn parent(self: *const FounderIndex) []const u32 {
        return self.slice(u32, .parent, self.n);
    }

    pub fn sizeRaw(self: *const FounderIndex) []const u32 {
        return self.slice(u32, .size, self.n);
    }

    pub fn allocRaw(self: *const FounderIndex) []const u32 {
        return self.slice(u32, .alloc, self.n);
    }

    pub fn mtime(self: *const FounderIndex) []const u32 {
        return self.slice(u32, .mtime, self.n);
    }

    pub fn dirEntry(self: *const FounderIndex) []const u32 {
        return self.slice(u32, .dir_entry, self.d);
    }

    pub fn dirStart(self: *const FounderIndex) []const u32 {
        return self.slice(u32, .dir_start, self.d);
    }

    pub fn dirLen(self: *const FounderIndex) []const u32 {
        return self.slice(u32, .dir_len, self.d);
    }

    pub fn dirEnd(self: *const FounderIndex) []const u32 {
        return self.slice(u32, .dir_end, self.d);
    }

    pub fn dirPrior(self: *const FounderIndex) []const i8 {
        return self.slice(i8, .dir_prior, self.d);
    }

    pub fn dirParent(self: *const FounderIndex) []const u32 {
        return self.slice(u32, .dir_parent, self.d);
    }

    pub fn dirBytes(self: *const FounderIndex) []const u64 {
        return self.slice(u64, .dir_bytes, self.d);
    }

    pub fn dirAlloc(self: *const FounderIndex) []const u64 {
        return self.slice(u64, .dir_alloc, self.d);
    }

    pub fn nameEntsOff(self: *const FounderIndex) []const u32 {
        return self.slice(u32, .name_ents_off, self.u + 1);
    }

    pub fn nameEnts(self: *const FounderIndex) []const u32 {
        return self.slice(u32, .name_ents, self.n);
    }

    pub fn namePrior(self: *const FounderIndex) []const i8 {
        return self.slice(i8, .name_prior, self.u);
    }

    pub fn nameInfo(self: *const FounderIndex) []const NameInfo {
        return self.slice(NameInfo, .name_info, self.u);
    }

    pub fn nameExt(self: *const FounderIndex) []const u8 {
        return self.slice(u8, .name_ext, self.u);
    }

    pub fn extTable(self: *const FounderIndex) []const [16]u8 {
        return self.slice([16]u8, .exts, 256);
    }

    pub fn zones(self: *const FounderIndex) []const Zone {
        return self.slice(Zone, .zones, self.zones_len);
    }

    pub fn big(self: *const FounderIndex) []const u64 {
        return self.slice(u64, .big, self.nbig);
    }

    pub fn uname(self: *const FounderIndex, id: u32) []const u8 {
        const o = self.nameOff();
        return self.names()[o[id]..o[id + 1]];
    }

    pub fn dirOf(self: *const FounderIndex, entry: u32) ?u32 {
        const de = self.dirEntry();
        var lo: usize = 0;
        var hi: usize = de.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (de[mid] < entry) lo = mid + 1 else if (de[mid] > entry) hi = mid else return @intCast(mid);
        }
        return null;
    }

    pub fn lookup(self: *const FounderIndex, path: []const u8) ?u32 {
        var e: u32 = 0;
        var it = std.mem.tokenizeScalar(u8, path, '/');
        while (it.next()) |comp| {
            const d = self.dirOf(e) orelse return null;
            const s = self.dirStart()[d];
            const l = self.dirLen()[d];
            var lo: usize = s;
            var hi: usize = s + l;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const nm = self.uname(self.entName()[mid]);
                if (std.mem.order(u8, nm, comp) == .lt) lo = mid + 1 else hi = mid;
            }
            if (lo < s + l and std.mem.eql(u8, self.uname(self.entName()[lo]), comp)) {
                e = @intCast(lo);
            } else {
                var found: ?u32 = null;
                for (s..s + l) |c| {
                    if (std.ascii.eqlIgnoreCase(self.uname(self.entName()[c]), comp)) {
                        found = @intCast(c);
                        break;
                    }
                }
                e = found orelse return null;
            }
        }
        return e;
    }
};
