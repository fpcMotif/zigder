const std = @import("std");
const index_read = @import("read.zig");
const live_mod = @import("live.zig");
const tcc = @import("tcc.zig");
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
        if (index_read.hasPathPrefix(p, pref)) return null;
    }
    return p;
}

pub fn resolveSyncDir(
    lv: *const live_mod.Live,
    canonical_path: []const u8,
    skip_paths: []const []const u8,
) ?[]const u8 {
    if (tcc.isBlocked(canonical_path, skip_paths)) return null;
    if (lv.hasDir(canonical_path)) return canonical_path;
    if (std.mem.eql(u8, canonical_path, "/")) return null;
    const parent = std.fs.path.dirname(canonical_path) orelse "/";
    if (std.mem.eql(u8, parent, "/")) {
        return if (!tcc.isBlocked("/", skip_paths) and lv.hasDir("/")) "/" else null;
    }
    var cur = parent;
    var steps: usize = 0;
    while (steps < 2) : (steps += 1) {
        if (!tcc.isBlocked(cur, skip_paths) and lv.hasDir(cur)) return cur;
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
    stopping: ?*const std.atomic.Value(bool),
) !FetchedTarget {
    const p = index_read.trimTrailingSlash(raw_path);
    var out: FetchedTarget = .{
        .path = try gpa.dupe(u8, p),
        .recursive = recursive,
    };
    errdefer out.deinit(gpa);

    if (tcc.isBlocked(p, skip_paths)) {
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
                out.scan = walk.scanCancel(gpa, p, skip_paths, 2, stopping) catch null;
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
        const child = index_read.joinBuf(&child_buf, p, name) orelse continue;
        if (cur.fetchRemove(name)) |kv| {
            lv.gpa.free(kv.key);
            if (kv.value) |c| {
                const was_kind = lv.base.kind()[c];
                if ((was_kind & 3) != (r.kind & 3)) {
                    lv.killSubtree(c);
                    try lv.putOverlay(child, r.kind, r.size, r.alloc, r.mtime);
                    if ((r.kind & 3) == walk.KIND_DIR and (r.kind & walk.FLAG_MOUNT) == 0 and !tcc.isBlocked(child, skip_paths)) {
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
                    if ((r.kind & 3) == walk.KIND_DIR and (r.kind & walk.FLAG_MOUNT) == 0 and !tcc.isBlocked(child, skip_paths)) {
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
            if ((r.kind & 3) == walk.KIND_DIR and (r.kind & walk.FLAG_MOUNT) == 0 and !tcc.isBlocked(child, skip_paths)) {
                try pending_subdirs.append(lv.gpa, try lv.gpa.dupe(u8, child));
            }
            mutated = true;
        }
    }

    var rem_it = cur.iterator();
    while (rem_it.next()) |kv| {
        const child = index_read.joinBuf(&child_buf, p, kv.key_ptr.*) orelse continue;
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
    stopping: ?*const std.atomic.Value(bool),
) !std.ArrayList(SubtreeScan) {
    var out: std.ArrayList(SubtreeScan) = .empty;
    errdefer {
        for (out.items) |*item| item.deinit(gpa);
        out.deinit(gpa);
    }
    for (paths) |p| {
        if (stopping) |s| if (s.load(.acquire)) break;
        if (tcc.isBlocked(p, skip_paths)) continue;
        const attrs = live_mod.lstatPath(p) orelse continue;
        if ((attrs.kind & 3) != walk.KIND_DIR or (attrs.kind & walk.FLAG_MOUNT) != 0) continue;
        const sc = walk.scanCancel(gpa, p, skip_paths, 2, stopping) catch null;
        try out.append(gpa, .{
            .path = try gpa.dupe(u8, p),
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
            const cp = try index_read.joinAlloc(lv.gpa, fr.dir_path, nm);
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

pub const TargetSpec = struct {
    path: []const u8,
    recursive: bool,
};

pub fn shouldWakeForDir(watch_dir: []const u8, mut_dir: []const u8) bool {
    if (watch_dir.len == 0) return false;
    if (std.mem.eql(u8, mut_dir, watch_dir)) return true;
    if (std.mem.eql(u8, mut_dir, "/")) return false;
    const mut_parent = std.fs.path.dirname(mut_dir) orelse "/";
    if (std.mem.eql(u8, mut_parent, watch_dir)) return true;
    if (index_read.hasPathPrefix(watch_dir, mut_dir)) return true;
    return false;
}

pub fn resolveTargets(
    gpa: std.mem.Allocator,
    lv: *const live_mod.Live,
    dirs: *const std.StringHashMapUnmanaged(bool),
    skip_paths: []const []const u8,
) std.ArrayList(TargetSpec) {
    var specs: std.ArrayList(TargetSpec) = .empty;
    var index_by_path: std.StringHashMapUnmanaged(usize) = .empty;
    defer index_by_path.deinit(gpa);
    var dit = dirs.iterator();
    while (dit.next()) |kv| {
        const resolved = resolveSyncDir(lv, kv.key_ptr.*, skip_paths) orelse continue;
        const rec = kv.value_ptr.* and std.mem.eql(u8, resolved, kv.key_ptr.*);
        if (index_by_path.get(resolved)) |idx| {
            specs.items[idx].recursive = specs.items[idx].recursive or rec;
            continue;
        }
        const key_copy = gpa.dupe(u8, resolved) catch continue;
        const idx = specs.items.len;
        specs.append(gpa, .{ .path = key_copy, .recursive = rec }) catch {
            gpa.free(key_copy);
            continue;
        };
        index_by_path.put(gpa, key_copy, idx) catch {};
    }
    return specs;
}

pub fn freeSpecs(gpa: std.mem.Allocator, list: *std.ArrayList(TargetSpec)) void {
    for (list.items) |sp| gpa.free(sp.path);
    list.deinit(gpa);
}

pub fn fetchTargets(
    gpa: std.mem.Allocator,
    specs: []const TargetSpec,
    skip_paths: []const []const u8,
    stopping: *const std.atomic.Value(bool),
) std.ArrayList(FetchedTarget) {
    var out: std.ArrayList(FetchedTarget) = .empty;
    for (specs) |spec| {
        if (stopping.load(.acquire)) break;
        const ft = fetchTarget(gpa, spec.path, spec.recursive, skip_paths, stopping) catch continue;
        out.append(gpa, ft) catch {
            var dead_ft = ft;
            dead_ft.deinit(gpa);
        };
    }
    return out;
}

pub fn freeFetched(gpa: std.mem.Allocator, list: *std.ArrayList(FetchedTarget)) void {
    for (list.items) |*ft| ft.deinit(gpa);
    list.deinit(gpa);
}

pub fn freeSubtrees(gpa: std.mem.Allocator, list: *std.ArrayList(SubtreeScan)) void {
    for (list.items) |*st| st.deinit(gpa);
    list.deinit(gpa);
}

pub fn freePaths(gpa: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |p| gpa.free(p);
    list.deinit(gpa);
}
