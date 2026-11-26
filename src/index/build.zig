const std = @import("std");
const fmt = @import("fmt.zig");
const accel = @import("accel.zig");
const walk = @import("walk.zig");
const Scratch = @import("scratch.zig").Scratch;
const measure = @import("../measure.zig");

const bundle_exts = [_][]const u8{
    ".framework",
    ".bundle",
    ".plugin",
    ".appex",
    ".kext",
    ".xpc",
    ".lproj",
    ".xcassets",
    ".photoslibrary",
    ".musiclibrary",
    ".tvlibrary",
    ".imovielibrary",
    ".dSYM",
    ".xcarchive",
    ".sdk",
    ".platform",
};

fn priorAdjust(name: []const u8, depth: u8) i32 {
    if (depth == 1) {
        if (std.mem.eql(u8, name, "Users")) return 0;
        if (std.mem.eql(u8, name, "Applications")) return 10;
        if (std.mem.eql(u8, name, "Volumes")) return -10;
        if (std.mem.eql(u8, name, "Library")) return -25;
        if (std.mem.eql(u8, name, "System")) return -40;
        if (std.mem.eql(u8, name, "opt")) return -25;
        return -35;
    }
    if (std.mem.eql(u8, name, "Applications")) return 30;
    if (std.mem.endsWith(u8, name, ".app")) return -25;
    for (bundle_exts) |ext| {
        if (name.len > ext.len and std.ascii.eqlIgnoreCase(name[name.len - ext.len ..], ext)) return -20;
    }
    if (name.len > 0 and name[0] == '.') return -25;
    if (std.mem.eql(u8, name, "Library")) return -20;
    if (std.mem.eql(u8, name, "Caches") or std.mem.eql(u8, name, "caches") or
        std.mem.eql(u8, name, "cache") or std.mem.eql(u8, name, "Cache") or
        std.mem.eql(u8, name, "Logs") or std.mem.eql(u8, name, "DerivedData") or
        std.mem.eql(u8, name, "CoreSimulator")) return -20;
    if (std.mem.eql(u8, name, "node_modules") or std.mem.eql(u8, name, "__pycache__") or
        std.mem.eql(u8, name, "site-packages") or std.mem.eql(u8, name, "Pods") or
        std.mem.eql(u8, name, "venv") or std.mem.eql(u8, name, "bower_components")) return -30;
    if (std.mem.eql(u8, name, "target") or std.mem.eql(u8, name, "build") or
        std.mem.eql(u8, name, "dist") or std.mem.eql(u8, name, "out") or
        std.mem.eql(u8, name, "vendor") or std.mem.eql(u8, name, "deps") or
        std.mem.eql(u8, name, "tmp") or std.mem.eql(u8, name, "temp")) return -12;
    if (std.mem.eql(u8, name, "folders") or std.mem.eql(u8, name, "Containers") or
        std.mem.eql(u8, name, "Group Containers")) return -10;
    if (std.mem.eql(u8, name, "Application Support")) return -5;
    return 0;
}

fn packSize(v: u64, unit: u64, big: *std.ArrayList(u64), arena: std.mem.Allocator) !u32 {
    if (v % unit == 0 and v / unit < fmt.BIG_FLAG) {
        return @intCast(v / unit);
    }
    const idx: u32 = @intCast(big.items.len);
    try big.append(arena, v);
    return fmt.BIG_FLAG | idx;
}

fn setNameBitmaps(ubits: []u64, words: usize, k: usize, s: []const u8) void {
    const bit: u64 = @as(u64, 1) << @intCast(k & 63);
    const w = k >> 6;
    const mid = s.len / 2;
    const a_mask = fmt.charMask(s[0..mid]);
    const b_mask = fmt.charMask(s[mid..]);
    const dbl = fmt.doubledMask(s);
    const starts = fmt.nameMask(s) >> fmt.CLASSES;
    for (0..fmt.CLASSES) |c| {
        const cm = @as(u64, 1) << @intCast(c);
        if ((a_mask & cm) != 0) ubits[(fmt.BM_FIRST + c) * words + w] |= bit;
        if ((b_mask & cm) != 0) ubits[(fmt.BM_SECOND + c) * words + w] |= bit;
        if ((dbl & cm) != 0) ubits[(fmt.BM_DOUBLE + c) * words + w] |= bit;
    }
    for (0..23) |h| {
        if ((starts & (@as(u64, 1) << @intCast(h))) != 0) {
            ubits[(fmt.BM_START + h) * words + w] |= bit;
        }
    }
    if (s.len > 0 and s[0] == '.') ubits[fmt.BM_DOT * words + w] |= bit;
    if (std.mem.endsWith(u8, s, ".app")) ubits[fmt.BM_APP * words + w] |= bit;
}

fn extKey(name: []const u8) ?[16]u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
    const e = name[dot + 1 ..];
    if (e.len > 15) return null;
    var key: [16]u8 = @splat(0);
    key[0] = @intCast(e.len);
    for (e, 0..) |b, i| key[1 + i] = fmt.fold(b);
    return key;
}

const ExtCount = struct {
    key: [16]u8,
    count: u32,
};

fn buildExts(
    arena: std.mem.Allocator,
    unames: []const u8,
    uoff: []const u32,
    u: usize,
) !struct { table: [256][16]u8, slots: []u8 } {
    var counts: std.AutoHashMapUnmanaged([16]u8, u32) = .empty;
    for (0..u) |k| {
        const nm = unames[uoff[k]..uoff[k + 1]];
        if (extKey(nm)) |ek| {
            const gop = try counts.getOrPut(arena, ek);
            if (gop.found_existing) gop.value_ptr.* += 1 else gop.value_ptr.* = 1;
        }
    }
    const list = try arena.alloc(ExtCount, counts.count());
    var it = counts.iterator();
    var li: usize = 0;
    while (it.next()) |e| {
        list[li] = .{ .key = e.key_ptr.*, .count = e.value_ptr.* };
        li += 1;
    }
    std.mem.sort(ExtCount, list, {}, struct {
        fn lessThan(_: void, a: ExtCount, b: ExtCount) bool {
            if (a.count != b.count) return a.count > b.count;
            return std.mem.order(u8, a.key[1 .. 1 + a.key[0]], b.key[1 .. 1 + b.key[0]]) == .lt;
        }
    }.lessThan);

    var table: [256][16]u8 = @splat(@splat(0));
    var slot_map: std.AutoHashMapUnmanaged([16]u8, u8) = .empty;
    const take = @min(list.len, 254);
    for (0..take) |i| {
        table[i + 1] = list[i].key;
        try slot_map.put(arena, list[i].key, @intCast(i + 1));
    }
    const slots = try arena.alloc(u8, u);
    for (0..u) |k| {
        const nm = unames[uoff[k]..uoff[k + 1]];
        if (extKey(nm)) |ek| {
            slots[k] = slot_map.get(ek) orelse 255;
        } else {
            slots[k] = if (std.mem.indexOfScalar(u8, nm, '.') != null) 255 else 0;
        }
    }
    return .{ .table = table, .slots = slots };
}

pub fn buildFromFounder(founder: *const fmt.FounderIndex, dest_path: []const u8) !void {
    var arena_state = Scratch.init();
    defer {
        arena_state.deinit();
        measure.releaseHeap();
    }
    const arena = arena_state.allocator();
    try accel.writeZsidx(arena, .{
        .n = founder.n,
        .d = founder.d,
        .u = founder.u,
        .names_len = founder.names_len,
        .nbig = founder.nbig,
        .event_id = founder.event_id,
        .synced_at = founder.synced_at,
        .name_bits = founder.nameBits(),
        .name_off = founder.nameOff(),
        .names = founder.names(),
        .name_info = founder.nameInfo(),
        .name_prior = founder.namePrior(),
        .name_ext = founder.nameExt(),
        .exts = founder.extTable(),
        .name_ents_off = founder.nameEntsOff(),
        .name_ents = founder.nameEnts(),
        .ent_name = founder.entName(),
        .kind = founder.kind(),
        .parent = founder.parent(),
        .size = founder.sizeRaw(),
        .alloc = founder.allocRaw(),
        .mtime = founder.mtime(),
        .dir_entry = founder.dirEntry(),
        .dir_start = founder.dirStart(),
        .dir_len = founder.dirLen(),
        .dir_end = founder.dirEnd(),
        .dir_prior = founder.dirPrior(),
        .dir_parent = founder.dirParent(),
        .dir_bytes = founder.dirBytes(),
        .dir_alloc = founder.dirAlloc(),
        .zones = founder.zones(),
        .big = founder.big(),
    }, dest_path);
}

const Block = struct {
    entry: u32,
    start: u32,
    len: u32,
};

const StackPair = struct {
    entry: u32,
    listing_idx: u32,
};

pub fn buildFromListings(
    listings: []walk.Listing,
    event_id: u64,
    synced_at: u32,
    home: []const u8,
    dest_path: []const u8,
) !void {
    var arena_state = Scratch.init();
    defer {
        arena_state.deinit();
        measure.releaseHeap();
    }
    const arena = arena_state.allocator();

    for (listings) |*l| {
        const names_slice = l.names.items;
        std.mem.sort(walk.RawEnt, l.ents.items, names_slice, struct {
            fn lessThan(ns: []const u8, a: walk.RawEnt, b: walk.RawEnt) bool {
                const an = ns[a.name_off..][0..a.name_len];
                const bn = ns[b.name_off..][0..b.name_len];
                return std.mem.order(u8, an, bn) == .lt;
            }
        }.lessThan);
    }

    var max_id: u32 = 0;
    for (listings) |l| {
        if (l.id > max_id) max_id = l.id;
    }
    const by_id = try arena.alloc(u32, max_id + 1);
    @memset(by_id, walk.NONE);
    for (listings, 0..) |l, i| by_id[l.id] = @intCast(i);

    var n_max: usize = 1;
    var names_max: usize = 0;
    for (listings) |l| {
        n_max += l.ents.items.len;
        names_max += l.names.items.len;
    }

    const raw_name_off = try arena.alloc(u32, n_max);
    const raw_name_len = try arena.alloc(u16, n_max);
    const kind = try arena.alloc(u8, n_max);
    const parent = try arena.alloc(u32, n_max);
    const size = try arena.alloc(u32, n_max);
    const alloc_arr = try arena.alloc(u32, n_max);
    const mtime = try arena.alloc(u32, n_max);
    @memset(raw_name_off, 0);
    @memset(raw_name_len, 0);
    @memset(kind, 0);
    @memset(parent, 0);
    @memset(size, 0);
    @memset(alloc_arr, 0);
    @memset(mtime, 0);

    var big: std.ArrayList(u64) = .empty;
    var raw_names: std.ArrayList(u8) = .empty;
    try raw_names.ensureTotalCapacity(arena, names_max);

    kind[0] = walk.KIND_DIR;
    var pos: usize = 1;
    var blocks: std.ArrayList(Block) = .empty;
    try blocks.ensureTotalCapacity(arena, listings.len);
    var stack: std.ArrayList(StackPair) = .empty;
    if (by_id[0] != walk.NONE) {
        try stack.append(arena, .{ .entry = 0, .listing_idx = by_id[0] });
    }
    var kids: std.ArrayList(StackPair) = .empty;

    while (stack.pop()) |top| {
        const l = &listings[top.listing_idx];
        const start = pos;
        kids.clearRetainingCapacity();
        for (l.ents.items) |r| {
            raw_name_off[pos] = @intCast(raw_names.items.len);
            raw_name_len[pos] = r.name_len;
            raw_names.appendSliceAssumeCapacity(l.names.items[r.name_off..][0..r.name_len]);
            kind[pos] = r.kind;
            size[pos] = try packSize(r.size, 1, &big, arena);
            alloc_arr[pos] = try packSize(r.alloc, fmt.ALLOC_UNIT, &big, arena);
            mtime[pos] = r.mtime;
            parent[pos] = top.entry;
            if (r.child < by_id.len and by_id[r.child] != walk.NONE) {
                try kids.append(arena, .{ .entry = @intCast(pos), .listing_idx = by_id[r.child] });
            }
            pos += 1;
        }
        try blocks.append(arena, .{ .entry = top.entry, .start = @intCast(start), .len = @intCast(pos - start) });
        var ki = kids.items.len;
        while (ki > 0) {
            ki -= 1;
            try stack.append(arena, kids.items[ki]);
        }
    }
    if (blocks.items.len == 0) {
        try blocks.append(arena, .{ .entry = 0, .start = 1, .len = 0 });
    }

    const n = pos;
    std.mem.sort(Block, blocks.items, {}, struct {
        fn lessThan(_: void, a: Block, b: Block) bool {
            return a.entry < b.entry;
        }
    }.lessThan);
    const d = blocks.items.len;

    const dir_of = try arena.alloc(u32, n);
    @memset(dir_of, walk.NONE);
    for (blocks.items, 0..) |b, k| dir_of[b.entry] = @intCast(k);
    for (0..n) |i| parent[i] = dir_of[parent[i]];
    parent[0] = 0;

    var ids: std.StringHashMapUnmanaged(u32) = .empty;
    try ids.ensureTotalCapacity(arena, @intCast(@max(n / 3, 64)));
    const ent_name = try arena.alloc(u32, n);
    var uoff: std.ArrayList(u32) = .empty;
    try uoff.append(arena, 0);
    var unames: std.ArrayList(u8) = .empty;
    try unames.ensureTotalCapacity(arena, @max(raw_names.items.len / 2, 64));

    for (0..n) |i| {
        const nm = raw_names.items[raw_name_off[i]..][0..raw_name_len[i]];
        const gop = try ids.getOrPut(arena, nm);
        if (!gop.found_existing) {
            const next_id: u32 = @intCast(uoff.items.len - 1);
            try unames.appendSlice(arena, nm);
            try uoff.append(arena, @intCast(unames.items.len));
            gop.key_ptr.* = unames.items[uoff.items[next_id]..uoff.items[next_id + 1]];
            gop.value_ptr.* = next_id;
        }
        ent_name[i] = gop.value_ptr.*;
    }

    const u = uoff.items.len - 1;
    const words = std.math.divCeil(usize, u, 64) catch unreachable;
    const ubits = try arena.alloc(u64, words * fmt.NBITMAPS);
    @memset(ubits, 0);
    for (0..u) |k| {
        setNameBitmaps(ubits, words, k, unames.items[uoff.items[k]..uoff.items[k + 1]]);
    }

    const ne_off = try arena.alloc(u32, u + 1);
    @memset(ne_off, 0);
    for (ent_name) |id| ne_off[id + 1] += 1;
    for (0..u) |k| ne_off[k + 1] += ne_off[k];
    const fill = try arena.dupe(u32, ne_off[0..u]);
    const ne = try arena.alloc(u32, n);
    for (ent_name, 0..) |id, i| {
        ne[fill[id]] = @intCast(i);
        fill[id] += 1;
    }

    const dir_entry = try arena.alloc(u32, d);
    const dir_start = try arena.alloc(u32, d);
    const dir_len = try arena.alloc(u32, d);
    const dir_end = try arena.alloc(u32, d);
    const dir_bytes = try arena.alloc(u64, d);
    const dir_alloc = try arena.alloc(u64, d);
    const dir_parent = try arena.alloc(u32, d);
    for (blocks.items, 0..) |b, k| {
        dir_entry[k] = b.entry;
        dir_start[k] = b.start;
        dir_len[k] = b.len;
        dir_end[k] = b.start + b.len;
        dir_parent[k] = parent[b.entry];
        var bs: u64 = 0;
        var ba: u64 = 0;
        for (b.start..b.start + b.len) |ei| {
            bs += fmt.unpackSize(size[ei], 1, big.items);
            ba += fmt.unpackSize(alloc_arr[ei], fmt.ALLOC_UNIT, big.items);
        }
        dir_bytes[k] = bs;
        dir_alloc[k] = ba;
    }
    var dk = d;
    while (dk > 1) {
        dk -= 1;
        const p = parent[dir_entry[dk]];
        dir_end[p] = @max(dir_end[p], dir_end[dk]);
        dir_bytes[p] += dir_bytes[dk];
        dir_alloc[p] += dir_alloc[dk];
    }

    var comps: std.ArrayList([]const u8) = .empty;
    var h_it = std.mem.tokenizeScalar(u8, home, '/');
    while (h_it.next()) |comp| try comps.append(arena, comp);

    const dir_prior = try arena.alloc(i8, d);
    const depth = try arena.alloc(u8, d);
    const hm = try arena.alloc(u8, d);
    @memset(dir_prior, 0);
    @memset(depth, 0);
    @memset(hm, 0);
    for (1..d) |k| {
        const e = dir_entry[k];
        const p = parent[e];
        const nm = raw_names.items[raw_name_off[e]..][0..raw_name_len[e]];
        depth[k] = depth[p] +| 1;
        hm[k] = if (hm[p] == 255)
            255
        else if (hm[p] >= comps.items.len)
            hm[p]
        else if (std.mem.eql(u8, comps.items[hm[p]], nm))
            hm[p] + 1
        else
            255;
        const entered_home = hm[k] == comps.items.len and hm[p] < comps.items.len;
        const adj = priorAdjust(nm, depth[k]) + @as(i32, if (entered_home) 15 else 0);
        dir_prior[k] = @intCast(std.math.clamp(@as(i32, dir_prior[p]) + adj, -100, 60));
    }

    for (0..u) |k| {
        const slice = ne[ne_off[k]..ne_off[k + 1]];
        if (slice.len > 1) {
            const Ctx = struct { p: []const u32, dp: []const i8 };
            std.mem.sort(u32, slice, Ctx{ .p = parent[0..n], .dp = dir_prior }, struct {
                fn lessThan(c: Ctx, a: u32, b: u32) bool {
                    const pa = c.dp[c.p[a]];
                    const pb = c.dp[c.p[b]];
                    if (pa != pb) return pa > pb;
                    return a < b;
                }
            }.lessThan);
        }
    }

    const name_prior = try arena.alloc(i8, u);
    @memset(name_prior, std.math.minInt(i8));
    for (1..n) |i| {
        const k = ent_name[i];
        const p = dir_prior[parent[i]];
        if (p > name_prior[k]) name_prior[k] = p;
    }

    const name_info = try arena.alloc(fmt.NameInfo, u);
    for (0..u) |k| {
        name_info[k] = fmt.nameInfoOf(unames.items[uoff.items[k]..uoff.items[k + 1]], name_prior[k]);
    }

    const ext_res = try buildExts(arena, unames.items, uoff.items, u);
    const zlen = std.math.divCeil(usize, n, fmt.ZONE) catch unreachable;
    const zones = try arena.alloc(fmt.Zone, zlen);
    for (0..zlen) |z| {
        const s = z * fmt.ZONE;
        const e = @min((z + 1) * fmt.ZONE, n);
        var max_sz: u64 = 0;
        var min_mt: u32 = std.math.maxInt(u32);
        var max_mt: u32 = 0;
        var kmask: u32 = 0;
        for (s..e) |i| {
            max_sz = @max(max_sz, fmt.unpackSize(size[i], 1, big.items));
            min_mt = @min(min_mt, mtime[i]);
            max_mt = @max(max_mt, mtime[i]);
            kmask |= @as(u32, 1) << @intCast(kind[i] & 3);
        }
        zones[z] = .{ .max_size = max_sz, .min_mtime = min_mt, .max_mtime = max_mt, .kinds = kmask };
    }

    try accel.writeZsidx(arena, .{
        .n = n,
        .d = d,
        .u = u,
        .names_len = unames.items.len,
        .nbig = big.items.len,
        .event_id = event_id,
        .synced_at = synced_at,
        .name_bits = ubits,
        .name_off = uoff.items,
        .names = unames.items,
        .name_info = name_info,
        .name_prior = name_prior,
        .name_ext = ext_res.slots,
        .exts = &ext_res.table,
        .name_ents_off = ne_off,
        .name_ents = ne,
        .ent_name = ent_name,
        .kind = kind[0..n],
        .parent = parent[0..n],
        .size = size[0..n],
        .alloc = alloc_arr[0..n],
        .mtime = mtime[0..n],
        .dir_entry = dir_entry,
        .dir_start = dir_start,
        .dir_len = dir_len,
        .dir_end = dir_end,
        .dir_prior = dir_prior,
        .dir_parent = dir_parent,
        .dir_bytes = dir_bytes,
        .dir_alloc = dir_alloc,
        .zones = zones,
        .big = big.items,
    }, dest_path);
}
