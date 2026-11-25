const std = @import("std");
const fmt = @import("fmt.zig");
const index_read = @import("read.zig");
const walk = @import("walk.zig");

extern "c" fn lstat(path: [*:0]const u8, buf: *std.c.Stat) c_int;

const UF_HIDDEN: u32 = 0x00008000;

pub const OverlayEntry = struct {
    path_off: u32,
    path_len: u16,
    name_off: u16,
    kind: u8,
    prior: i8,
    alive: bool,
    mtime: u32,
    size: u64,
    alloc: u64,
    mask: u64,
};

pub const DirOverride = struct {
    kind: u8,
    mtime: u32,
};

pub const LiveEntry = struct {
    kind: u8,
    size: u64,
    mtime: u32,
};

const OverlayCtx = struct {
    names: *const std.ArrayList(u8),
    items: *const std.ArrayList(OverlayEntry),

    pub fn hash(ctx: OverlayCtx, slot: u32) u64 {
        const e = ctx.items.items[slot];
        return std.hash.Wyhash.hash(0, ctx.names.items[e.path_off..][0..e.path_len]);
    }

    pub fn eql(ctx: OverlayCtx, a: u32, b: u32) bool {
        if (a == b) return true;
        const ea = ctx.items.items[a];
        const eb = ctx.items.items[b];
        return std.mem.eql(
            u8,
            ctx.names.items[ea.path_off..][0..ea.path_len],
            ctx.names.items[eb.path_off..][0..eb.path_len],
        );
    }
};

const OverlaySliceAdapter = struct {
    names: *const std.ArrayList(u8),
    items: *const std.ArrayList(OverlayEntry),

    pub fn hash(_: OverlaySliceAdapter, key: []const u8) u64 {
        return std.hash.Wyhash.hash(0, key);
    }

    pub fn eql(ctx: OverlaySliceAdapter, key: []const u8, slot: u32) bool {
        const e = ctx.items.items[slot];
        return std.mem.eql(u8, key, ctx.names.items[e.path_off..][0..e.path_len]);
    }
};

pub const Live = struct {
    gpa: std.mem.Allocator,
    base: index_read.Index,
    dead: []u64,
    dead_count: usize = 0,
    event_id: u64,
    synced_at: u32,
    overlay_names: std.ArrayList(u8) = .empty,
    overlay_items: std.ArrayList(OverlayEntry) = .empty,
    overlay_map: std.HashMapUnmanaged(u32, void, OverlayCtx, 80) = .empty,
    free_slots: std.ArrayList(u32) = .empty,
    alive_overlay_count: usize = 0,
    dir_overrides: std.AutoHashMapUnmanaged(u32, DirOverride) = .empty,
    priors: std.StringHashMapUnmanaged(i8) = .empty,

    pub fn init(gpa: std.mem.Allocator, base: index_read.Index) !Live {
        const nwords = std.math.divCeil(usize, base.n, 64) catch unreachable;
        const dead = try gpa.alloc(u64, nwords);
        @memset(dead, 0);
        return .{
            .gpa = gpa,
            .base = base,
            .dead = dead,
            .event_id = base.event_id,
            .synced_at = base.synced_at,
        };
    }

    pub fn deinit(self: *Live) void {
        self.gpa.free(self.dead);
        self.overlay_names.deinit(self.gpa);
        self.overlay_items.deinit(self.gpa);
        self.overlay_map.deinit(self.gpa);
        self.free_slots.deinit(self.gpa);
        self.dir_overrides.deinit(self.gpa);
        var it = self.priors.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.priors.deinit(self.gpa);
        self.base.deinit();
    }

    pub inline fn isDead(self: *const Live, i: u32) bool {
        if (self.dead_count == 0) return false;
        return (self.dead[i >> 6] & (@as(u64, 1) << @intCast(i & 63))) != 0;
    }

    pub fn kill(self: *Live, i: u32) void {
        const w = &self.dead[i >> 6];
        const bit = @as(u64, 1) << @intCast(i & 63);
        if ((w.* & bit) == 0) {
            w.* |= bit;
            self.dead_count += 1;
        }
    }

    fn killRange(self: *Live, s: usize, end: usize) void {
        if (s >= end) return;
        var at = s & ~@as(usize, 63);
        while (at < end) : (at += 64) {
            const wi = at >> 6;
            if (wi >= self.dead.len) break;
            var mask: u64 = std.math.maxInt(u64);
            if (at < s) mask &= ~@as(u64, 0) << @as(u6, @intCast(s - at));
            if (end - at < 64) mask &= (@as(u64, 1) << @as(u6, @intCast(end - at))) - 1;
            const prev = self.dead[wi];
            const added = mask & ~prev;
            if (added != 0) {
                self.dead[wi] = prev | mask;
                self.dead_count += @popCount(added);
            }
        }
    }

    pub fn killSubtree(self: *Live, e: u32) void {
        self.kill(e);
        if (self.base.dirOf(e)) |d| {
            self.killRange(self.base.dirStart()[d], self.base.dirEnd()[d]);
        }
    }

    pub inline fn kindOf(self: *const Live, i: u32) u8 {
        if (self.dir_overrides.size > 0) {
            if (self.dir_overrides.get(i)) |ov| return ov.kind;
        }
        return self.base.kind()[i];
    }

    pub inline fn mtimeOf(self: *const Live, i: u32) u32 {
        if (self.dir_overrides.size > 0) {
            if (self.dir_overrides.get(i)) |ov| return ov.mtime;
        }
        return self.base.mtime()[i];
    }

    pub fn redate(self: *Live, i: u32, kind: u8, mtime: u32) void {
        if (kind == self.base.kind()[i] and mtime == self.base.mtime()[i]) {
            _ = self.dir_overrides.remove(i);
        } else {
            self.dir_overrides.put(self.gpa, i, .{ .kind = kind, .mtime = mtime }) catch {};
        }
    }

    pub fn overlayPath(self: *const Live, e: OverlayEntry) []const u8 {
        return self.overlay_names.items[e.path_off..][0..e.path_len];
    }

    pub fn overlayName(self: *const Live, e: OverlayEntry) []const u8 {
        return self.overlay_names.items[e.path_off + e.name_off .. e.path_off + e.path_len];
    }

    pub fn lookupOverlay(self: *const Live, path: []const u8) ?u32 {
        if (self.overlay_map.count() == 0) return null;
        const adapter: OverlaySliceAdapter = .{ .names = &self.overlay_names, .items = &self.overlay_items };
        return self.overlay_map.getKeyAdapted(path, adapter);
    }

    pub fn hasDir(self: *const Live, raw_path: []const u8) bool {
        const p = index_read.trimTrailingSlash(raw_path);
        if (self.baseAlive(p)) |e| return self.base.dirOf(e) != null;
        const slot = self.lookupOverlay(p) orelse return false;
        const o = self.overlay_items.items[slot];
        return o.alive and (o.kind & 3) == walk.KIND_DIR and (o.kind & walk.FLAG_MOUNT) == 0;
    }

    fn parentPrior(self: *Live, parent_path: []const u8) i8 {
        if (parent_path.len == 0) return 0;
        if (self.priors.get(parent_path)) |p| return p;
        var up = parent_path;
        var prior: i8 = 0;
        while (up.len > 0) {
            if (self.base.lookup(up)) |e| {
                if (self.base.dirOf(e)) |d| {
                    prior = self.base.dirPrior()[d];
                    break;
                }
            }
            const cut = std.mem.lastIndexOfScalar(u8, up, '/') orelse 0;
            up = up[0..cut];
        }
        const key = self.gpa.dupe(u8, parent_path) catch return prior;
        self.priors.put(self.gpa, key, prior) catch self.gpa.free(key);
        return prior;
    }

    pub fn putOverlay(self: *Live, raw_path: []const u8, kind: u8, size: u64, alloc: u64, mtime: u32) !void {
        const path = index_read.trimTrailingSlash(raw_path);
        if (path.len > std.math.maxInt(u16)) return;
        const cut = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
        const name_off: u16 = @intCast(if (cut + 1 <= path.len) cut + 1 else 0);
        const name = path[name_off..];
        const prior = self.parentPrior(path[0..cut]);
        const mask = fmt.nameMask(name);

        if (self.lookupOverlay(path)) |slot| {
            var item = &self.overlay_items.items[slot];
            if (!item.alive) self.alive_overlay_count += 1;
            item.kind = kind;
            item.prior = prior;
            item.alive = true;
            item.mtime = mtime;
            item.size = size;
            item.alloc = alloc;
            item.mask = mask;
            return;
        }
        const ctx: OverlayCtx = .{ .names = &self.overlay_names, .items = &self.overlay_items };
        if (self.free_slots.pop()) |slot| {
            var item = &self.overlay_items.items[slot];
            const off: u32 = if (path.len <= item.path_len) blk: {
                @memcpy(self.overlay_names.items[item.path_off..][0..path.len], path);
                break :blk item.path_off;
            } else blk: {
                const next_off: u32 = @intCast(self.overlay_names.items.len);
                try self.overlay_names.appendSlice(self.gpa, path);
                break :blk next_off;
            };
            item.* = .{
                .path_off = off,
                .path_len = @intCast(path.len),
                .name_off = name_off,
                .kind = kind,
                .prior = prior,
                .alive = true,
                .mtime = mtime,
                .size = size,
                .alloc = alloc,
                .mask = mask,
            };
            self.overlay_map.putContext(self.gpa, slot, {}, ctx) catch |err| {
                item.alive = false;
                self.free_slots.append(self.gpa, slot) catch {};
                return err;
            };
            self.alive_overlay_count += 1;
            return;
        }
        const off: u32 = @intCast(self.overlay_names.items.len);
        try self.overlay_names.appendSlice(self.gpa, path);
        const slot: u32 = @intCast(self.overlay_items.items.len);
        try self.overlay_items.append(self.gpa, .{
            .path_off = off,
            .path_len = @intCast(path.len),
            .name_off = name_off,
            .kind = kind,
            .prior = prior,
            .alive = true,
            .mtime = mtime,
            .size = size,
            .alloc = alloc,
            .mask = mask,
        });
        try self.overlay_map.putContext(self.gpa, slot, {}, ctx);
        self.alive_overlay_count += 1;
    }

    pub fn dropOverlaySubtree(self: *Live, path: []const u8) void {
        if (self.alive_overlay_count == 0) return;
        const ctx: OverlayCtx = .{ .names = &self.overlay_names, .items = &self.overlay_items };
        for (self.overlay_items.items, 0..) |*item, si| {
            if (!item.alive) continue;
            const ip = self.overlay_names.items[item.path_off..][0..item.path_len];
            if (index_read.hasPathPrefix(ip, path)) {
                item.alive = false;
                self.alive_overlay_count -|= 1;
                _ = self.overlay_map.removeContext(@intCast(si), ctx);
                self.free_slots.append(self.gpa, @intCast(si)) catch {};
            }
        }
    }

    pub fn baseAlive(self: *const Live, path: []const u8) ?u32 {
        const e = self.base.lookup(path) orelse return null;
        if (self.isDead(e)) return null;
        return e;
    }

    pub fn removePath(self: *Live, raw_path: []const u8) void {
        const p = index_read.trimTrailingSlash(raw_path);
        if (self.baseAlive(p)) |e| self.killSubtree(e);
        self.dropOverlaySubtree(p);
    }

    pub fn entry(self: *const Live, raw_path: []const u8) ?LiveEntry {
        const p = index_read.trimTrailingSlash(raw_path);
        if (self.baseAlive(p)) |e| {
            return .{
                .kind = self.kindOf(e),
                .size = self.base.sizeOf(e),
                .mtime = self.mtimeOf(e),
            };
        }
        const slot = self.lookupOverlay(p) orelse return null;
        const o = self.overlay_items.items[slot];
        if (!o.alive) return null;
        return .{ .kind = o.kind, .size = o.size, .mtime = o.mtime };
    }

    fn baseDirTotals(self: *const Live, d: u32) fmt.Totals {
        var t = self.base.dirTotals(d);
        if (self.dead_count > 0) {
            const s = self.base.dirStart()[d];
            const end = self.base.dirEnd()[d];
            const Ctx = struct { live: *const Live, t: *fmt.Totals };
            var ctx: Ctx = .{ .live = self, .t = &t };
            eachDead(self.dead, s, end, &ctx, struct {
                fn sub(c: *Ctx, i: u32) void {
                    c.t.bytes -|= c.live.base.sizeOf(i);
                    c.t.allocated -|= c.live.base.allocOf(i);
                    c.t.items -|= 1;
                }
            }.sub);
        }
        if (self.dead_count > 0 or self.dir_overrides.count() > 0) {
            const r = self.base.children(d);
            var vis: u64 = 0;
            for (r.start..r.end) |c| {
                if (self.isDead(@intCast(c))) continue;
                const nm = self.base.name(c);
                if (nm.len > 0 and nm[0] != '.' and (self.kindOf(@intCast(c)) & walk.FLAG_HIDDEN) == 0) vis += 1;
            }
            t.visible = vis;
        }
        return t;
    }

    pub fn totals(self: *const Live, raw_path: []const u8) ?fmt.Totals {
        const p = index_read.trimTrailingSlash(raw_path);
        var t: fmt.Totals = .{};
        var found = false;
        if (self.baseAlive(p)) |e| {
            if (self.base.dirOf(e)) |d| {
                found = true;
                t = self.baseDirTotals(d);
            }
        } else if (self.lookupOverlay(p)) |slot| {
            const o = self.overlay_items.items[slot];
            if (o.alive and (o.kind & 3) == walk.KIND_DIR and (o.kind & walk.FLAG_MOUNT) == 0) found = true;
        }
        if (!found) return null;
        if (self.alive_overlay_count == 0) return t;

        for (self.overlay_items.items) |o| {
            if (!o.alive) continue;
            const ip = self.overlayPath(o);
            const rel = underRel(p, ip) orelse continue;
            t.bytes += o.size;
            t.allocated += o.alloc;
            t.items += 1;
            if (std.mem.indexOfScalar(u8, rel, '/') == null) {
                if (rel.len > 0 and rel[0] != '.' and (o.kind & walk.FLAG_HIDDEN) == 0) t.visible += 1;
            }
        }
        return t;
    }

    pub fn folderTotals(self: *const Live, raw_dir: []const u8, gpa: std.mem.Allocator) !?index_read.FolderTotals {
        const p = index_read.trimTrailingSlash(raw_dir);
        const be = self.baseAlive(p);
        const bd = if (be) |e| self.base.dirOf(e) else null;
        if (bd == null) {
            const slot = self.lookupOverlay(p) orelse return null;
            const o = self.overlay_items.items[slot];
            if (!o.alive or (o.kind & 3) != walk.KIND_DIR or (o.kind & walk.FLAG_MOUNT) != 0) return null;
        }
        var items: std.ArrayList(index_read.FolderTotalEntry) = .empty;
        errdefer items.deinit(gpa);
        var names: std.ArrayList(u8) = .empty;
        errdefer names.deinit(gpa);
        if (self.alive_overlay_count == 0) {
            if (bd) |d| {
                const r = self.base.children(d);
                for (r.start..r.end) |c| {
                    if (self.isDead(@intCast(c))) continue;
                    const cd = self.base.dirOf(@intCast(c)) orelse continue;
                    const nm = self.base.name(c);
                    const off: u32 = @intCast(names.items.len);
                    try names.appendSlice(gpa, nm);
                    try items.append(gpa, .{
                        .name_off = off,
                        .name_len = @intCast(nm.len),
                        .totals = self.baseDirTotals(cd),
                    });
                }
            }
            const owned_items = try items.toOwnedSlice(gpa);
            errdefer gpa.free(owned_items);
            const owned_names = try names.toOwnedSlice(gpa);
            return .{ .items = owned_items, .names = owned_names };
        }

        const Accum = struct {
            name: []const u8,
            totals: fmt.Totals = .{},
            is_dir: bool = false,
        };
        var accs: std.ArrayList(Accum) = .empty;
        defer accs.deinit(gpa);
        var map: std.StringHashMapUnmanaged(usize) = .empty;
        defer map.deinit(gpa);

        if (bd) |d| {
            const r = self.base.children(d);
            try accs.ensureTotalCapacity(gpa, r.end - r.start);
            for (r.start..r.end) |c| {
                if (self.isDead(@intCast(c))) continue;
                const cd = self.base.dirOf(@intCast(c)) orelse continue;
                const nm = self.base.name(c);
                try map.put(gpa, nm, accs.items.len);
                accs.appendAssumeCapacity(.{
                    .name = nm,
                    .totals = self.baseDirTotals(cd),
                    .is_dir = true,
                });
            }
        }
        for (self.overlay_items.items) |o| {
            if (!o.alive) continue;
            const ip = self.overlayPath(o);
            const rel = underRel(p, ip) orelse continue;
            const slash = std.mem.indexOfScalar(u8, rel, '/');
            const cname = if (slash) |si| rel[0..si] else rel;
            const gop = try map.getOrPut(gpa, cname);
            if (!gop.found_existing) {
                gop.value_ptr.* = accs.items.len;
                try accs.append(gpa, .{ .name = cname });
            }
            const acc = &accs.items[gop.value_ptr.*];
            if (slash) |si| {
                acc.totals.bytes += o.size;
                acc.totals.allocated += o.alloc;
                acc.totals.items += 1;
                const sub_rel = rel[si + 1 ..];
                if (std.mem.indexOfScalar(u8, sub_rel, '/') == null) {
                    if (sub_rel.len > 0 and sub_rel[0] != '.' and (o.kind & walk.FLAG_HIDDEN) == 0) {
                        acc.totals.visible += 1;
                    }
                }
            } else if ((o.kind & 3) == walk.KIND_DIR and (o.kind & walk.FLAG_MOUNT) == 0) {
                acc.is_dir = true;
            }
        }
        for (accs.items) |acc| {
            if (acc.is_dir) {
                const off: u32 = @intCast(names.items.len);
                try names.appendSlice(gpa, acc.name);
                try items.append(gpa, .{
                    .name_off = off,
                    .name_len = @intCast(acc.name.len),
                    .totals = acc.totals,
                });
            }
        }
        const owned_items = try items.toOwnedSlice(gpa);
        errdefer gpa.free(owned_items);
        const owned_names = try names.toOwnedSlice(gpa);
        return .{ .items = owned_items, .names = owned_names };
    }
};

pub fn eachDead(dead: []const u64, s: usize, end: usize, ctx: anytype, comptime cb: fn (@TypeOf(ctx), u32) void) void {
    if (s >= end or dead.len == 0) return;
    var at = s & ~@as(usize, 63);
    while (at < end) : (at += 64) {
        const wi = at >> 6;
        if (wi >= dead.len) break;
        var bits = dead[wi];
        if (at < s) bits &= ~@as(u64, 0) << @as(u6, @intCast(s - at));
        if (end - at < 64) bits &= (@as(u64, 1) << @as(u6, @intCast(end - at))) - 1;
        while (bits != 0) {
            const bit = @ctz(bits);
            bits &= bits - 1;
            cb(ctx, @intCast(at + bit));
        }
    }
}

pub const LstatRes = struct {
    kind: u8,
    size: u64,
    alloc: u64,
    mtime: u32,
};

pub fn lstatPath(path: []const u8) ?LstatRes {
    var buf: [2048]u8 = undefined;
    const cpath = std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0) catch return null;
    var st: std.c.Stat = undefined;
    if (lstat(cpath, &st) != 0) return null;
    var kind: u8 = walk.kindFromMode(st.mode);
    if ((st.flags & UF_HIDDEN) != 0) kind |= walk.FLAG_HIDDEN;
    if ((kind & 3) != walk.KIND_DIR and st.nlink > 1) kind |= walk.FLAG_HARDLINK;
    const mt = st.mtimespec.sec;
    return .{
        .kind = kind,
        .size = @intCast(@max(st.size, 0)),
        .alloc = @as(u64, @intCast(@max(st.blocks, 0))) * 512,
        .mtime = if (mt <= 0) 0 else @intCast(@min(mt, std.math.maxInt(u32))),
    };
}


pub fn directChildName(dir: []const u8, full: []const u8) ?[]const u8 {
    const rel = underRel(dir, full) orelse return null;
    if (std.mem.indexOfScalar(u8, rel, '/') != null) return null;
    return rel;
}

fn underRel(dir: []const u8, full: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, dir, "/")) {
        if (full.len <= 1 or full[0] != '/') return null;
        return full[1..];
    }
    if (full.len <= dir.len + 1 or !std.mem.startsWith(u8, full, dir) or full[dir.len] != '/') return null;
    return full[dir.len + 1 ..];
}
