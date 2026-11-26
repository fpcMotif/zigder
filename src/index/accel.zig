const std = @import("std");
const fmt = @import("fmt.zig");
const walk = @import("walk.zig");

extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn fsync(fd: c_int) c_int;
extern "c" fn rename(old: [*:0]const u8, new: [*:0]const u8) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: u16) c_int;

const O_WRONLY: c_int = 0x0001;
const O_CREAT: c_int = 0x0200;
const O_TRUNC: c_int = 0x0400;

pub const IndexSlices = struct {
    n: usize,
    d: usize,
    u: usize,
    names_len: usize,
    nbig: usize,
    event_id: u64,
    synced_at: u32,
    name_bits: []const u64,
    name_off: []const u32,
    names: []const u8,
    name_info: []const fmt.NameInfo,
    name_prior: []const i8,
    name_ext: []const u8,
    exts: []const [16]u8,
    name_ents_off: []const u32,
    name_ents: []const u32,
    ent_name: []const u32,
    kind: []const u8,
    parent: []const u32,
    size: []const u32,
    alloc: []const u32,
    mtime: []const u32,
    dir_entry: []const u32,
    dir_start: []const u32,
    dir_len: []const u32,
    dir_end: []const u32,
    dir_prior: []const i8,
    dir_parent: []const u32,
    dir_bytes: []const u64,
    dir_alloc: []const u64,
    zones: []const fmt.Zone,
    big: []const u64,
};

fn extractUniqueTrigrams(name: []const u8, out_buf: []u32) []const u32 {
    if (name.len < 3) return out_buf[0..0];
    const count = name.len - 2;
    const dst = out_buf[0..count];
    for (0..count) |i| {
        dst[i] = fmt.trigramId(name[i], name[i + 1], name[i + 2]);
    }
    if (count <= 32) {
        for (1..count) |i| {
            const key = dst[i];
            var j = i;
            while (j > 0 and dst[j - 1] > key) : (j -= 1) {
                dst[j] = dst[j - 1];
            }
            dst[j] = key;
        }
    } else {
        std.mem.sort(u32, dst, {}, std.sort.asc(u32));
    }
    var uniq: usize = 0;
    for (dst) |t| {
        if (uniq == 0 or dst[uniq - 1] != t) {
            dst[uniq] = t;
            uniq += 1;
        }
    }
    return dst[0..uniq];
}

const BufferedWriter = struct {
    fd: c_int,
    buf: [256 * 1024]u8 = undefined,
    pos: usize = 0,
    written: usize = 0,

    fn writeBytes(w: *BufferedWriter, data: []const u8) !void {
        w.written += data.len;
        if (data.len >= w.buf.len) {
            try w.flush();
            try writeAllFd(w.fd, data);
            return;
        }
        if (w.pos + data.len > w.buf.len) {
            try w.flush();
        }
        @memcpy(w.buf[w.pos .. w.pos + data.len], data);
        w.pos += data.len;
    }

    fn writeZeroes(w: *BufferedWriter, n: usize) !void {
        var rem = n;
        const zeros: [64]u8 = @splat(0);
        while (rem > 0) {
            const chunk = @min(rem, zeros.len);
            try w.writeBytes(zeros[0..chunk]);
            rem -= chunk;
        }
    }

    fn writeSlice(w: *BufferedWriter, comptime T: type, items: []const T) !void {
        if (items.len == 0) return;
        const bytes: [*]const u8 = @ptrCast(items.ptr);
        try w.writeBytes(bytes[0 .. items.len * @sizeOf(T)]);
    }

    fn padTo(w: *BufferedWriter, target: usize) !void {
        if (target > w.written) {
            try w.writeZeroes(target - w.written);
        }
    }

    fn flush(w: *BufferedWriter) !void {
        if (w.pos > 0) {
            try writeAllFd(w.fd, w.buf[0..w.pos]);
            w.pos = 0;
        }
    }
};

fn writeAllFd(fd: c_int, data: []const u8) !void {
    var at: usize = 0;
    while (at < data.len) {
        const rc = write(fd, data.ptr + at, data.len - at);
        if (rc < 0) {
            if (std.c.errno(rc) == .INTR) continue;
            return error.WriteFailed;
        }
        at += @intCast(rc);
    }
}

pub fn writeFd(fd: c_int, bytes: []const u8) void {
    writeAllFd(fd, bytes) catch {};
}

pub fn ensureParentDir(path: []const u8) void {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    if (slash == 0) return;
    const dir = path[0..slash];
    var buf: [2048]u8 = undefined;
    if (dir.len >= buf.len) return;
    @memcpy(buf[0..dir.len], dir);
    var i: usize = 1;
    while (i <= dir.len) : (i += 1) {
        if (i == dir.len or buf[i] == '/') {
            const saved = buf[i];
            buf[i] = 0;
            _ = mkdir(@ptrCast(&buf), 0o755);
            buf[i] = saved;
        }
    }
}

pub fn writeZsidx(arena: std.mem.Allocator, src: IndexSlices, dest_path: []const u8) !void {
    const u = src.u;
    const words = std.math.divCeil(usize, u, 64) catch unreachable;

    var class_counts: [fmt.CLASSES * 2]u32 = @splat(0);
    for (0..fmt.CLASSES) |c| {
        const b0 = src.name_bits[(fmt.BM_FIRST + c) * words ..][0..words];
        const b1 = src.name_bits[(fmt.BM_SECOND + c) * words ..][0..words];
        const bd = src.name_bits[(fmt.BM_DOUBLE + c) * words ..][0..words];
        var cnt: u32 = 0;
        var dcnt: u32 = 0;
        for (0..words) |w| {
            cnt += @popCount(b0[w] | b1[w]);
            dcnt += @popCount(bd[w]);
        }
        class_counts[c] = cnt;
        class_counts[fmt.CLASSES + c] = dcnt;
    }

    var top_prior: i8 = if (u == 0) 0 else std.math.minInt(i8);
    for (src.name_prior) |p| {
        if (p > top_prior) top_prior = p;
    }

    var by_key_counts: [256]u32 = @splat(0);
    var head_counts: [fmt.HEAD_BUCKETS]u32 = @splat(0);
    for (src.name_info) |ni| {
        by_key_counts[@intCast(@as(i32, ni.key) + 128)] += 1;
        head_counts[fmt.charClass(ni.head)] += 1;
    }

    var cover: i32 = std.math.maxInt(i8) + 1;
    var nby_key: usize = 0;
    while (cover > std.math.minInt(i8)) {
        const next_c = by_key_counts[@intCast(cover - 1 + 128)];
        if (nby_key + next_c > fmt.BY_KEY_WANT) break;
        cover -= 1;
        nby_key += next_c;
    }

    var key_fill: [256]u32 = undefined;
    var key_acc: u32 = 0;
    var k_idx: usize = 256;
    while (k_idx > 0) {
        k_idx -= 1;
        key_fill[k_idx] = key_acc;
        key_acc += by_key_counts[k_idx];
    }

    const sorted_names = try arena.alloc(u32, u);
    for (src.name_info, 0..) |ni, id| {
        const b: usize = @intCast(@as(i32, ni.key) + 128);
        sorted_names[key_fill[b]] = @intCast(id);
        key_fill[b] += 1;
    }

    const tri_off = try arena.alloc(u32, fmt.TRIGRAM_BUCKETS + 1);
    @memset(tri_off, 0);

    var stack_tri: [1024]u32 = undefined;
    for (0..u) |id| {
        const nm = src.names[src.name_off[id]..src.name_off[id + 1]];
        const tbuf = if (nm.len >= 3 and nm.len - 2 > stack_tri.len)
            try arena.alloc(u32, nm.len - 2)
        else
            &stack_tri;
        const tris = extractUniqueTrigrams(nm, tbuf);
        for (tris) |t| tri_off[t] += 1;
    }

    var tri_acc: u32 = 0;
    for (0..fmt.TRIGRAM_BUCKETS) |t| {
        const c = tri_off[t];
        tri_off[t] = tri_acc;
        tri_acc += c;
    }
    tri_off[fmt.TRIGRAM_BUCKETS] = tri_acc;
    const ntri_posts: usize = tri_acc;

    const tri_fill = try arena.dupe(u32, tri_off[0..fmt.TRIGRAM_BUCKETS]);
    const tri_posts = try arena.alloc(u32, ntri_posts);

    var head_off: [fmt.HEAD_BUCKETS + 1]u32 = undefined;
    var head_fill: [fmt.HEAD_BUCKETS]u32 = undefined;
    var head_acc: u32 = 0;
    for (0..fmt.HEAD_BUCKETS) |h| {
        head_off[h] = head_acc;
        head_fill[h] = head_acc;
        head_acc += head_counts[h];
    }
    head_off[fmt.HEAD_BUCKETS] = head_acc;
    const head_posts = try arena.alloc(u32, u);

    for (sorted_names) |id| {
        const hc = fmt.charClass(src.name_info[id].head);
        head_posts[head_fill[hc]] = id;
        head_fill[hc] += 1;
        const nm = src.names[src.name_off[id]..src.name_off[id + 1]];
        const tbuf = if (nm.len >= 3 and nm.len - 2 > stack_tri.len)
            try arena.alloc(u32, nm.len - 2)
        else
            &stack_tri;
        const tris = extractUniqueTrigrams(nm, tbuf);
        for (tris) |t| {
            tri_posts[tri_fill[t]] = id;
            tri_fill[t] += 1;
        }
    }

    var nmarked: usize = 0;
    for (src.kind) |kv| {
        if ((kv & (walk.FLAG_MOUNT | walk.FLAG_HARDLINK)) != 0) nmarked += 1;
    }
    const marked = try arena.alloc(u32, nmarked);
    var mp: usize = 0;
    for (src.kind, 0..) |kv, ei| {
        if ((kv & (walk.FLAG_MOUNT | walk.FLAG_HARDLINK)) != 0) {
            marked[mp] = @intCast(ei);
            mp += 1;
        }
    }

    const lay = try fmt.computeLayout(fmt.NZSEC, try fmt.zsectionLens(
        src.n,
        src.d,
        u,
        src.names_len,
        src.nbig,
        ntri_posts,
        u,
        nby_key,
        nmarked,
    ));

    ensureParentDir(dest_path);
    const tmp_path = try std.fmt.allocPrintSentinel(arena, "{s}.tmp", .{dest_path}, 0);
    const dest_z = try arena.dupeSentinel(u8, dest_path, 0);

    const fd = open(tmp_path, O_WRONLY | O_CREAT | O_TRUNC, @as(c_int, 0o644));
    if (fd < 0) return error.OpenFailed;
    errdefer _ = close(fd);

    const bw = try arena.create(BufferedWriter);
    bw.* = .{ .fd = fd };

    var hdr: [fmt.HDR]u8 = @splat(0);
    @memcpy(hdr[0..8], fmt.MAGIC_ZSIDX);
    const cover_i64: i64 = cover;
    const top_u8: u8 = @bitCast(top_prior);
    const fields = [_]u64{
        src.n,
        src.d,
        u,
        src.names_len,
        src.event_id,
        src.synced_at,
        src.nbig,
        ntri_posts,
        u,
        nby_key,
        @bitCast(cover_i64),
        top_u8,
        nmarked,
    };
    for (fields, 0..) |fv, fi| {
        std.mem.writeInt(u64, hdr[8 + fi * 8 ..][0..8], fv, .little);
    }
    try bw.writeBytes(&hdr);

    const o = lay.off;
    try bw.padTo(o[@backingInt(fmt.ZSec.trigram_off)]);
    try bw.writeSlice(u32, tri_off);
    try bw.padTo(o[@backingInt(fmt.ZSec.trigram_posts)]);
    try bw.writeSlice(u32, tri_posts);
    try bw.padTo(o[@backingInt(fmt.ZSec.head_off)]);
    try bw.writeSlice(u32, &head_off);
    try bw.padTo(o[@backingInt(fmt.ZSec.head_posts)]);
    try bw.writeSlice(u32, head_posts);
    try bw.padTo(o[@backingInt(fmt.ZSec.by_key)]);
    try bw.writeSlice(u32, sorted_names[0..nby_key]);
    try bw.padTo(o[@backingInt(fmt.ZSec.by_key_counts)]);
    try bw.writeSlice(u32, &by_key_counts);
    try bw.padTo(o[@backingInt(fmt.ZSec.name_bits)]);
    try bw.writeSlice(u64, src.name_bits);
    try bw.padTo(o[@backingInt(fmt.ZSec.class_counts)]);
    try bw.writeSlice(u32, &class_counts);
    try bw.padTo(o[@backingInt(fmt.ZSec.name_off)]);
    try bw.writeSlice(u32, src.name_off);
    try bw.padTo(o[@backingInt(fmt.ZSec.names)]);
    try bw.writeBytes(src.names);
    try bw.writeZeroes(64);
    try bw.padTo(o[@backingInt(fmt.ZSec.name_info)]);
    try bw.writeSlice(fmt.NameInfo, src.name_info);
    try bw.padTo(o[@backingInt(fmt.ZSec.name_prior)]);
    try bw.writeSlice(i8, src.name_prior);
    try bw.padTo(o[@backingInt(fmt.ZSec.name_ext)]);
    try bw.writeSlice(u8, src.name_ext);
    try bw.padTo(o[@backingInt(fmt.ZSec.exts)]);
    try bw.writeSlice([16]u8, src.exts);
    try bw.padTo(o[@backingInt(fmt.ZSec.name_ents_off)]);
    try bw.writeSlice(u32, src.name_ents_off);
    try bw.padTo(o[@backingInt(fmt.ZSec.name_ents)]);
    try bw.writeSlice(u32, src.name_ents);
    try bw.padTo(o[@backingInt(fmt.ZSec.ent_name)]);
    try bw.writeSlice(u32, src.ent_name);
    try bw.padTo(o[@backingInt(fmt.ZSec.kind)]);
    try bw.writeBytes(src.kind);
    try bw.padTo(o[@backingInt(fmt.ZSec.parent)]);
    try bw.writeSlice(u32, src.parent);
    try bw.padTo(o[@backingInt(fmt.ZSec.size)]);
    try bw.writeSlice(u32, src.size);
    try bw.padTo(o[@backingInt(fmt.ZSec.alloc)]);
    try bw.writeSlice(u32, src.alloc);
    try bw.padTo(o[@backingInt(fmt.ZSec.mtime)]);
    try bw.writeSlice(u32, src.mtime);
    try bw.padTo(o[@backingInt(fmt.ZSec.dir_entry)]);
    try bw.writeSlice(u32, src.dir_entry);
    try bw.padTo(o[@backingInt(fmt.ZSec.dir_start)]);
    try bw.writeSlice(u32, src.dir_start);
    try bw.padTo(o[@backingInt(fmt.ZSec.dir_len)]);
    try bw.writeSlice(u32, src.dir_len);
    try bw.padTo(o[@backingInt(fmt.ZSec.dir_end)]);
    try bw.writeSlice(u32, src.dir_end);
    try bw.padTo(o[@backingInt(fmt.ZSec.dir_prior)]);
    try bw.writeSlice(i8, src.dir_prior);
    try bw.padTo(o[@backingInt(fmt.ZSec.dir_parent)]);
    try bw.writeSlice(u32, src.dir_parent);
    try bw.padTo(o[@backingInt(fmt.ZSec.dir_bytes)]);
    try bw.writeSlice(u64, src.dir_bytes);
    try bw.padTo(o[@backingInt(fmt.ZSec.dir_alloc)]);
    try bw.writeSlice(u64, src.dir_alloc);
    try bw.padTo(o[@backingInt(fmt.ZSec.zones)]);
    try bw.writeSlice(fmt.Zone, src.zones);
    try bw.padTo(o[@backingInt(fmt.ZSec.big)]);
    try bw.writeSlice(u64, src.big);
    try bw.padTo(o[@backingInt(fmt.ZSec.marked)]);
    try bw.writeSlice(u32, marked);
    try bw.padTo(lay.total);
    try bw.flush();
    _ = fsync(fd);
    _ = close(fd);
    if (rename(tmp_path, dest_z) != 0) return error.RenameFailed;
}
