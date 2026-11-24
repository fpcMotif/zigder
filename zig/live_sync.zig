const std = @import("std");
const index_read = @import("index_read.zig");
const live_mod = @import("live.zig");
const walk = @import("walk.zig");

const LstatRes = live_mod.LstatRes;

const system_ignore_prefixes = [_][]const u8{
    "/dev",
    "/Volumes",
    "/System/Volumes",
    "/.Spotlight-V100",
    "/.fseventsd",
    "/.DocumentRevisions-V100",
    "/.TemporaryItems",
    "/private/var/vm",
    "/cores",
};

pub fn hasPathPrefix(path: []const u8, prefix: []const u8) bool {
    if (std.mem.eql(u8, prefix, "/")) return path.len > 0 and path[0] == '/';
    return std.mem.startsWith(u8, path, prefix) and (path.len == prefix.len or path[prefix.len] == '/');
}

pub fn canonicalEventPath(raw: []const u8) ?[]const u8 {
    var p = index_read.trimTrailingSlash(raw);
    if (p.len == 0 or p[0] != '/') return null;
    const data_prefix = "/System/Volumes/Data";
    if (std.mem.eql(u8, p, data_prefix)) {
        p = "/";
    } else if (std.mem.startsWith(u8, p, data_prefix) and p[data_prefix.len] == '/') {
        p = p[data_prefix.len..];
    }
    for (system_ignore_prefixes) |pref| {
        if (hasPathPrefix(p, pref)) return null;
    }
    return p;
}

pub fn resolveSyncDir(
    lv: *const live_mod.Live,
    canonical_path: []const u8,
    skip_paths: []const []const u8,
) ?[]const u8 {
    if (walk.isBlocked(canonical_path, skip_paths)) return null;
    if (lv.hasDir(canonical_path)) return canonical_path;
    if (std.mem.eql(u8, canonical_path, "/")) return null;
    const parent = std.fs.path.dirname(canonical_path) orelse "/";
    if (std.mem.eql(u8, parent, "/")) {
        return if (!walk.isBlocked("/", skip_paths) and lv.hasDir("/")) "/" else null;
    }
    var cur = parent;
    var steps: usize = 0;
    while (steps < 2) : (steps += 1) {
        if (!walk.isBlocked(cur, skip_paths) and lv.hasDir(cur)) return cur;
        const next_parent = std.fs.path.dirname(cur) orelse "/";
        if (std.mem.eql(u8, next_parent, "/")) break;
        cur = next_parent;
    }
    return null;
}

pub const FetchedTarget = struct {
    path: []u8,
    recursive: bool,
    blocked: bool = false,
    need_rebuild: bool = false,
    attrs: ?LstatRes = null,
    has_listing: bool = false,
    listing: walk.Listing = .{ .id = 0 },
    scan: ?walk.ScanResult = null,

    pub fn deinit(f: *FetchedTarget, gpa: std.mem.Allocator) void {
        gpa.free(f.path);
        f.listing.deinit(gpa);
        if (f.scan) |*sc| sc.deinit();
    }
};

pub const SubtreeScan = struct {
    path: []u8,
    attrs: LstatRes,
    scan: ?walk.ScanResult = null,

    pub fn deinit(st: *SubtreeScan, gpa: std.mem.Allocator) void {
        gpa.free(st.path);
        if (st.scan) |*sc| sc.deinit();
    }
};

pub fn fetchTarget(
    gpa: std.mem.Allocator,
    raw_path: []const u8,
    recursive: bool,
    skip_paths: []const []const u8,
) !FetchedTarget {
    const p = index_read.trimTrailingSlash(raw_path);
    var out: FetchedTarget = .{
        .path = try gpa.dupe(u8, p),
        .recursive = recursive,
    };
    errdefer out.deinit(gpa);

    if (walk.isBlocked(p, skip_paths)) {
        out.blocked = true;
        return out;
    }
    if (recursive) {
        if (std.mem.eql(u8, p, "/")) {
            out.need_rebuild = true;
            return out;
        }
        out.attrs = live_mod.lstatPath(p);
        if (out.attrs) |a| {
            if ((a.kind & 3) == walk.KIND_DIR and (a.kind & walk.FLAG_MOUNT) == 0) {
                out.scan = walk.scan(gpa, p, skip_paths, 2) catch null;
            }
        }
        return out;
    }
    out.attrs = live_mod.lstatPath(p);
    out.has_listing = walk.listOne(gpa, p, &out.listing);
    return out;
}

pub const ApplyOutcome = struct {
    mutated: bool = false,
    need_rebuild: bool = false,
};

pub fn applyFetched(
    lv: *live_mod.Live,
    f: *FetchedTarget,
    skip_paths: []const []const u8,
    pending_subdirs: *std.ArrayList([]u8),
) !ApplyOutcome {
    if (f.blocked) return .{};
    if (f.need_rebuild) return .{ .need_rebuild = true };
    const p = f.path;

    if (f.recursive) {
        const had_before = lv.entry(p) != null;
        lv.removePath(p);
        if (f.attrs) |a| {
            try lv.putOverlay(p, a.kind, a.size, a.alloc, a.mtime);
            if (f.scan) |*sc| try insertScan(lv, p, sc);
            return .{ .mutated = true };
        }
        return .{ .mutated = had_before };
    }

    if (!f.has_listing) {
        if (f.attrs == null) {
            const had_before = lv.entry(p) != null;
            lv.removePath(p);
            return .{ .mutated = had_before };
        }
        return .{};
    }

    var cur: std.StringHashMapUnmanaged(?u32) = .empty;
    defer {
        var kit = cur.keyIterator();
        while (kit.next()) |k| lv.gpa.free(k.*);
        cur.deinit(lv.gpa);
    }

    if (lv.baseAlive(p)) |be| {
        if (lv.base.dirOf(be)) |d| {
            const r = lv.base.children(d);
            for (r.start..r.end) |c| {
                if (!lv.isDead(@intCast(c))) {
                    const nm = try lv.gpa.dupe(u8, lv.base.name(c));
                    try cur.put(lv.gpa, nm, @intCast(c));
                }
            }
        }
    }
    if (lv.alive_overlay_count > 0) {
        for (lv.overlay_items.items) |item| {
            if (!item.alive) continue;
            const ip = lv.overlayPath(item);
            if (live_mod.directChildName(p, ip)) |cname| {
                const nm = try lv.gpa.dupe(u8, cname);
                const gop = try cur.getOrPut(lv.gpa, nm);
                if (gop.found_existing) {
                    lv.gpa.free(nm);
                }
                gop.value_ptr.* = null;
            }
        }
    }

    var mutated = false;
    var child_buf: [2048]u8 = undefined;
    for (f.listing.ents.items) |r| {
        const name = f.listing.entName(r);
        const child = live_mod.joinBuf(&child_buf, p, name) orelse continue;
        if (cur.fetchRemove(name)) |kv| {
            lv.gpa.free(kv.key);
            if (kv.value) |c| {
                const was_kind = lv.base.kind()[c];
                if ((was_kind & 3) != (r.kind & 3)) {
                    lv.killSubtree(c);
                    try lv.putOverlay(child, r.kind, r.size, r.alloc, r.mtime);
                    if ((r.kind & 3) == walk.KIND_DIR and (r.kind & walk.FLAG_MOUNT) == 0 and !walk.isBlocked(child, skip_paths)) {
                        try pending_subdirs.append(lv.gpa, try lv.gpa.dupe(u8, child));
                    }
                    mutated = true;
                } else if ((r.kind & 3) == walk.KIND_DIR) {
                    if (lv.kindOf(c) != r.kind or lv.mtimeOf(c) != r.mtime) {
                        lv.redate(c, r.kind, r.mtime);
                        mutated = true;
                    }
                } else if (was_kind != r.kind or lv.base.sizeOf(c) != r.size or lv.base.allocOf(c) != r.alloc or lv.base.mtime()[c] != r.mtime) {
                    lv.kill(c);
                    try lv.putOverlay(child, r.kind, r.size, r.alloc, r.mtime);
                    mutated = true;
                }
            } else if (lv.lookupOverlay(child)) |slot| {
                const old = lv.overlay_items.items[slot];
                if ((old.kind & 3) != (r.kind & 3)) {
                    lv.dropOverlaySubtree(child);
                    try lv.putOverlay(child, r.kind, r.size, r.alloc, r.mtime);
                    if ((r.kind & 3) == walk.KIND_DIR and (r.kind & walk.FLAG_MOUNT) == 0 and !walk.isBlocked(child, skip_paths)) {
                        try pending_subdirs.append(lv.gpa, try lv.gpa.dupe(u8, child));
                    }
                    mutated = true;
                } else if (old.kind != r.kind or old.size != r.size or old.alloc != r.alloc or old.mtime != r.mtime) {
                    try lv.putOverlay(child, r.kind, r.size, r.alloc, r.mtime);
                    mutated = true;
                }
            }
        } else {
            try lv.putOverlay(child, r.kind, r.size, r.alloc, r.mtime);
            if ((r.kind & 3) == walk.KIND_DIR and (r.kind & walk.FLAG_MOUNT) == 0 and !walk.isBlocked(child, skip_paths)) {
                try pending_subdirs.append(lv.gpa, try lv.gpa.dupe(u8, child));
            }
            mutated = true;
        }
    }

    var rem_it = cur.iterator();
    while (rem_it.next()) |kv| {
        const child = live_mod.joinBuf(&child_buf, p, kv.key_ptr.*) orelse continue;
        if (kv.value_ptr.*) |c| {
            lv.killSubtree(c);
        } else {
            lv.dropOverlaySubtree(child);
        }
        mutated = true;
    }

    if (f.attrs) |a| {
        if (lv.baseAlive(p)) |e| {
            const k = (lv.kindOf(e) & ~walk.FLAG_HIDDEN) | (a.kind & walk.FLAG_HIDDEN);
            if (lv.kindOf(e) != k or lv.mtimeOf(e) != a.mtime) {
                lv.redate(e, k, a.mtime);
                mutated = true;
            }
        } else if (lv.lookupOverlay(p)) |slot| {
            const o = lv.overlay_items.items[slot];
            if (o.alive) {
                const k = (o.kind & ~walk.FLAG_HIDDEN) | (a.kind & walk.FLAG_HIDDEN);
                if (o.kind != k or o.mtime != a.mtime) {
                    try lv.putOverlay(p, k, o.size, o.alloc, a.mtime);
                    mutated = true;
                }
            }
        }
    }

    return .{ .mutated = mutated };
}

pub fn fetchSubtrees(
    gpa: std.mem.Allocator,
    paths: []const []u8,
    skip_paths: []const []const u8,
) !std.ArrayList(SubtreeScan) {
    var out: std.ArrayList(SubtreeScan) = .empty;
    errdefer {
        for (out.items) |*item| item.deinit(gpa);
        out.deinit(gpa);
    }
    for (paths) |p| {
        if (walk.isBlocked(p, skip_paths)) continue;
        const attrs = live_mod.lstatPath(p) orelse continue;
        if ((attrs.kind & 3) != walk.KIND_DIR or (attrs.kind & walk.FLAG_MOUNT) != 0) continue;
        const sc = walk.scan(gpa, p, skip_paths, 2) catch null;
        try out.append(gpa, .{
            .path = try gpa.dupe(u8, p),
            .attrs = attrs,
            .scan = sc,
        });
    }
    return out;
}

pub fn applySubtrees(lv: *live_mod.Live, items: []SubtreeScan) !void {
    for (items) |*st| {
        if (lv.entry(st.path)) |cur| {
            if ((cur.kind & 3) != walk.KIND_DIR) continue;
        } else continue;
        if (st.scan) |*sc| {
            try insertScan(lv, st.path, sc);
        }
    }
}

fn insertScan(lv: *live_mod.Live, path: []const u8, scanned: *const walk.ScanResult) !void {
    var id_map: std.AutoHashMapUnmanaged(u32, usize) = .empty;
    defer id_map.deinit(lv.gpa);
    for (scanned.listings.items, 0..) |l, i| try id_map.put(lv.gpa, l.id, i);

    const Frame = struct { id: u32, dir_path: []u8 };
    var stack: std.ArrayList(Frame) = .empty;
    defer {
        for (stack.items) |fr| lv.gpa.free(fr.dir_path);
        stack.deinit(lv.gpa);
    }
    try stack.append(lv.gpa, .{ .id = 0, .dir_path = try lv.gpa.dupe(u8, path) });
    while (stack.pop()) |fr| {
        defer lv.gpa.free(fr.dir_path);
        const li = id_map.get(fr.id) orelse continue;
        const l = scanned.listings.items[li];
        for (l.ents.items) |r| {
            const nm = l.entName(r);
            const cp = if (std.mem.eql(u8, fr.dir_path, "/"))
                try std.fmt.allocPrint(lv.gpa, "/{s}", .{nm})
            else
                try std.fmt.allocPrint(lv.gpa, "{s}/{s}", .{ fr.dir_path, nm });
            errdefer lv.gpa.free(cp);
            try lv.putOverlay(cp, r.kind, r.size, r.alloc, r.mtime);
            if (r.child != walk.NONE) {
                try stack.append(lv.gpa, .{ .id = r.child, .dir_path = cp });
            } else {
                lv.gpa.free(cp);
            }
        }
    }
}

pub fn applyDir(
    lv: *live_mod.Live,
    raw_path: []const u8,
    recursive: bool,
    skip_paths: []const []const u8,
) !bool {
    var f = try fetchTarget(lv.gpa, raw_path, recursive, skip_paths);
    defer f.deinit(lv.gpa);

    var pending: std.ArrayList([]u8) = .empty;
    defer {
        for (pending.items) |p| lv.gpa.free(p);
        pending.deinit(lv.gpa);
    }
    const res = try applyFetched(lv, &f, skip_paths, &pending);
    if (pending.items.len > 0) {
        var subs = try fetchSubtrees(lv.gpa, pending.items, skip_paths);
        defer {
            for (subs.items) |*s| s.deinit(lv.gpa);
            subs.deinit(lv.gpa);
        }
        try applySubtrees(lv, subs.items);
    }
    return res.need_rebuild;
}
