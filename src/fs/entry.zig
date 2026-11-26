const std = @import("std");
const walk = @import("../index/walk.zig");
const volumes = @import("volumes.zig");
const index_read = @import("../index/read.zig");
const fs_kind = @import("kind.zig");

pub const SortCol = enum {
    name,
    modified,
    size,
    kind,
    tags,
};

pub const FLAG_HIDDEN: u8 = 1 << 0;
pub const FLAG_PACKAGE: u8 = 1 << 1;
pub const FLAG_APP: u8 = 1 << 2;
pub const FLAG_SIZE_KNOWN: u8 = 1 << 3;

pub const DirEntry = struct {
    name_off: u32,
    name_len: u16,
    kind: u8,
    tag_mask: u8,
    ext_off: u16,
    flags: u8,
    pad: u8 = 0,
    mtime: u32,
    size: u64,
    dir_items: u32,
    pad2: u32 = 0,

    pub inline fn isHidden(e: DirEntry) bool {
        return (e.flags & FLAG_HIDDEN) != 0;
    }

    pub inline fn isDir(e: DirEntry) bool {
        return (e.kind & 3) == walk.KIND_DIR;
    }

    pub inline fn isPackage(e: DirEntry) bool {
        return (e.flags & FLAG_PACKAGE) != 0;
    }

    pub inline fn isApp(e: DirEntry) bool {
        return (e.flags & FLAG_APP) != 0;
    }

    pub inline fn isFolderRow(e: DirEntry) bool {
        return e.isDir() and !e.isPackage();
    }
};

comptime {
    if (@sizeOf(DirEntry) != 32) @compileError("DirEntry must be 32 bytes");
}

pub const FolderListing = struct {
    path: []u8 = &.{},
    entries: std.ArrayList(DirEntry) = .empty,
    names: std.ArrayList(u8) = .empty,
    order: std.ArrayList(u32) = .empty,

    pub fn deinit(l: *FolderListing, gpa: std.mem.Allocator) void {
        if (l.path.len > 0) gpa.free(l.path);
        l.entries.deinit(gpa);
        l.names.deinit(gpa);
        l.order.deinit(gpa);
        l.* = .{};
    }

    pub fn nameOf(l: *const FolderListing, e: DirEntry) []const u8 {
        return l.names.items[e.name_off..][0..e.name_len];
    }

    pub fn extOf(l: *const FolderListing, e: DirEntry) []const u8 {
        const nm = l.nameOf(e);
        if (e.ext_off >= nm.len) return "";
        return nm[e.ext_off..];
    }

    pub fn resort(
        l: *FolderListing,
        gpa: std.mem.Allocator,
        col: SortCol,
        ascending: bool,
        folders_first: bool,
        show_hidden: bool,
    ) !void {
        l.order.clearRetainingCapacity();
        for (l.entries.items, 0..) |e, i| {
            if (!show_hidden and e.isHidden()) continue;
            try l.order.append(gpa, @intCast(i));
        }
        const Ctx = struct {
            listing: *const FolderListing,
            col: SortCol,
            asc: bool,
            ff: bool,
        };
        std.mem.sort(u32, l.order.items, Ctx{
            .listing = l,
            .col = col,
            .asc = ascending,
            .ff = folders_first,
        }, struct {
            fn lessThan(c: Ctx, ai: u32, bi: u32) bool {
                const a = c.listing.entries.items[ai];
                const b = c.listing.entries.items[bi];
                if (c.ff) {
                    const af = a.isFolderRow();
                    const bf = b.isFolderRow();
                    if (af != bf) return af;
                }
                const na = c.listing.nameOf(a);
                const nb = c.listing.nameOf(b);
                const ord: std.math.Order = switch (c.col) {
                    .name => naturalCmp(na, nb),
                    .modified => std.math.order(a.mtime, b.mtime),
                    .size => std.math.order(a.size, b.size),
                    .kind => kindOrder(c.listing, a, b),
                    .tags => std.math.order(a.tag_mask, b.tag_mask),
                };
                const final_ord = if (ord == .eq) naturalCmp(na, nb) else ord;
                return if (c.asc) final_ord == .lt else final_ord == .gt;
            }
        }.lessThan);
    }
};

fn kindOrder(l: *const FolderListing, a: DirEntry, b: DirEntry) std.math.Order {
    const ka: u8 = if (a.isFolderRow()) 0 else if (a.isPackage()) 1 else 2;
    const kb: u8 = if (b.isFolderRow()) 0 else if (b.isPackage()) 1 else 2;
    if (ka != kb) return std.math.order(ka, kb);
    return naturalCmp(l.extOf(a), l.extOf(b));
}

pub fn loadFolder(
    gpa: std.mem.Allocator,
    raw_path: []const u8,
    folder_totals: ?*const index_read.FolderTotals,
    col: SortCol,
    ascending: bool,
    folders_first: bool,
    show_hidden: bool,
) !FolderListing {
    const clean = index_read.trimTrailingSlash(raw_path);
    var raw: walk.Listing = .{ .id = 0 };
    defer raw.deinit(gpa);
    if (!walk.listOne(gpa, clean, &raw)) return error.OpenDirFailed;

    var out: FolderListing = .{
        .path = try gpa.dupe(u8, clean),
    };
    errdefer out.deinit(gpa);

    try out.entries.ensureTotalCapacity(gpa, raw.ents.items.len);
    try out.names.ensureTotalCapacity(gpa, raw.names.items.len);

    for (raw.ents.items) |r| {
        const nm = raw.entName(r);
        const noff: u32 = @intCast(out.names.items.len);
        out.names.appendSliceAssumeCapacity(nm);

        const is_dir = (r.kind & 3) == walk.KIND_DIR;
        const is_pkg = is_dir and fs_kind.isPackageName(nm);
        const is_app = is_dir and fs_kind.isAppName(nm);
        const is_hidden = (nm.len > 0 and nm[0] == '.') or (r.kind & walk.FLAG_HIDDEN) != 0;

        var flags: u8 = 0;
        if (is_hidden) flags |= FLAG_HIDDEN;
        if (is_pkg) flags |= FLAG_PACKAGE;
        if (is_app) flags |= FLAG_APP;

        var sz = r.size;
        var items: u32 = 0;
        if (is_dir) {
            if (folder_totals) |ft| {
                if (ft.find(nm)) |tot| {
                    sz = tot.bytes;
                    items = @intCast(@min(tot.visible, std.math.maxInt(u32)));
                    flags |= FLAG_SIZE_KNOWN;
                }
            }
        } else {
            flags |= FLAG_SIZE_KNOWN;
        }

        var ext_off: u16 = @intCast(nm.len);
        if (!is_dir or is_pkg) ext_off = @intCast(nm.len - fs_kind.extOfName(nm).len);

        out.entries.appendAssumeCapacity(.{
            .name_off = noff,
            .name_len = @intCast(nm.len),
            .kind = r.kind,
            .tag_mask = 0,
            .ext_off = ext_off,
            .flags = flags,
            .mtime = r.mtime,
            .size = sz,
            .dir_items = items,
        });
    }
    readTags(&out);
    try out.resort(gpa, col, ascending, folders_first, show_hidden);
    return out;
}

const tag_workers = 4;
const parallel_tags_min = 256;

const TagSpan = struct {
    listing: *FolderListing,
    lo: usize,
    hi: usize,

    fn read(span: TagSpan) void {
        var buf: [2048]u8 = undefined;
        for (span.listing.entries.items[span.lo..span.hi]) |*e| {
            const full = index_read.joinBuf(&buf, span.listing.path, span.listing.nameOf(e.*)) orelse continue;
            e.tag_mask = volumes.readTagMask(full);
        }
    }
};

fn readTags(listing: *FolderListing) void {
    const n = listing.entries.items.len;
    const workers: usize = if (n < parallel_tags_min) 1 else tag_workers;
    const per = n / workers;
    var threads: [tag_workers]?std.Thread = @splat(null);
    for (1..workers) |w| {
        const span: TagSpan = .{ .listing = listing, .lo = w * per, .hi = if (w + 1 == workers) n else (w + 1) * per };
        threads[w] = std.Thread.spawn(.{}, TagSpan.read, .{span}) catch blk: {
            span.read();
            break :blk null;
        };
    }
    TagSpan.read(.{ .listing = listing, .lo = 0, .hi = if (workers == 1) n else per });
    for (threads) |t| if (t) |th| th.join();
}

pub fn naturalCmp(a: []const u8, b: []const u8) std.math.Order {
    var ia: usize = 0;
    var ib: usize = 0;
    while (ia < a.len and ib < b.len) {
        const ca = a[ia];
        const cb = b[ib];
        if (std.ascii.isDigit(ca) and std.ascii.isDigit(cb)) {
            var ea = ia;
            while (ea < a.len and std.ascii.isDigit(a[ea])) : (ea += 1) {}
            var eb = ib;
            while (eb < b.len and std.ascii.isDigit(b[eb])) : (eb += 1) {}
            var za = ia;
            while (za < ea and a[za] == '0') : (za += 1) {}
            var zb = ib;
            while (zb < eb and b[zb] == '0') : (zb += 1) {}
            const da = a[za..ea];
            const db = b[zb..eb];
            if (da.len != db.len) return std.math.order(da.len, db.len);
            const cmp = std.mem.order(u8, da, db);
            if (cmp != .eq) return cmp;
            if ((ea - ia) != (eb - ib)) return std.math.order(ea - ia, eb - ib);
            ia = ea;
            ib = eb;
        } else {
            const la = std.ascii.toLower(ca);
            const lb = std.ascii.toLower(cb);
            if (la != lb) return std.math.order(la, lb);
            ia += 1;
            ib += 1;
        }
    }
    if (a.len != b.len) return std.math.order(a.len, b.len);
    return std.mem.order(u8, a, b);
}
