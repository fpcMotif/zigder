const std = @import("std");
const accel = @import("index/accel.zig");
const fmt = @import("index/fmt.zig");
const index_read = @import("index/read.zig");
const index_build = @import("index/build.zig");
const live_mod = @import("index/live.zig");
const walk = @import("index/walk.zig");
const query_mod = @import("search/query.zig");
const search_mod = @import("search/search.zig");
const fs_entry = @import("fs/entry.zig");
const fs_ops = @import("fs/ops.zig");
const quicklook = @import("fs/quicklook.zig");
const fsevents = @import("index/fsevents.zig");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

fn printOut(gpa: std.mem.Allocator, comptime f: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(gpa, f, args) catch return;
    defer gpa.free(s);
    accel.writeFd(1, s);
}

fn printErr(gpa: std.mem.Allocator, comptime f: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(gpa, f, args) catch return;
    defer gpa.free(s);
    accel.writeFd(2, s);
}

fn openLive(gpa: std.mem.Allocator, zidx_path: []const u8, founder_path: []const u8) !live_mod.Live {
    if (index_read.Index.load(zidx_path)) |idx| {
        return try live_mod.Live.init(gpa, idx);
    } else |_| {}
    var f = try fmt.FounderIndex.load(founder_path);
    defer f.deinit();
    accel.ensureParentDir(zidx_path);
    try index_build.buildFromFounder(&f, zidx_path);
    const idx = try index_read.Index.load(zidx_path);
    return try live_mod.Live.init(gpa, idx);
}

fn writeJsonStr(gpa: std.mem.Allocator, s: []const u8) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    buf.append(gpa, '"') catch return;
    for (s) |ch| {
        switch (ch) {
            '"' => buf.appendSlice(gpa, "\\\"") catch return,
            '\\' => buf.appendSlice(gpa, "\\\\") catch return,
            '\n' => buf.appendSlice(gpa, "\\n") catch return,
            '\r' => buf.appendSlice(gpa, "\\r") catch return,
            '\t' => buf.appendSlice(gpa, "\\t") catch return,
            else => {
                if (ch < 0x20) {
                    var esc: [6]u8 = undefined;
                    const e = std.fmt.bufPrint(&esc, "\\u{x:0>4}", .{ch}) catch continue;
                    buf.appendSlice(gpa, e) catch return;
                } else {
                    buf.append(gpa, ch) catch return;
                }
            },
        }
    }
    buf.append(gpa, '"') catch return;
    accel.writeFd(1, buf.items);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const home = if (getenv("HOME")) |h| std.mem.span(h) else "/";
    const default_zidx = try std.fmt.allocPrint(gpa, "{s}/Library/Caches/zigder/index.zidx", .{home});
    defer gpa.free(default_zidx);
    const founder_path = try std.fmt.allocPrint(gpa, "{s}/Library/Application Support/Founder/fsearch/index.bin", .{home});
    defer gpa.free(founder_path);

    if (args.len < 2 or std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "help")) {
        accel.writeFd(1,
            \\zigder-cli commands:
            \\  ls [path] [--all] [--json]
            \\  search [--limit N] [--scope PATH] [--index PATH] [--json] <query...>
            \\  totals <path> [--index PATH] [--json]
            \\  info <path> [--index PATH] [--json]
            \\  copy <src> <dst_dir>
            \\  move <src> <dst_dir>
            \\  duplicate <path>
            \\  trash <path>
            \\  delete <path>
            \\  rename <path> <new_name>
            \\  new-folder <dir> [name]
            \\  new-file <dir> [name]
            \\  index-build [--from-founder] [--root PATH] [--out PATH]
            \\  index-status [--index PATH] [--json]
            \\
        );
        return;
    }

    const cmd = args[1];
    var json = false;
    var show_all = false;
    var from_founder = false;
    var limit: usize = 50;
    var scope_opt: ?[]const u8 = null;
    var idx_path: []const u8 = default_zidx;
    var root_path: []const u8 = "/";
    var out_path: []const u8 = default_zidx;
    var pos_args: std.ArrayList([]const u8) = .empty;
    defer pos_args.deinit(gpa);

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, a, "--all") or std.mem.eql(u8, a, "-a")) {
            show_all = true;
        } else if (std.mem.eql(u8, a, "--from-founder")) {
            from_founder = true;
        } else if (std.mem.eql(u8, a, "--limit") and i + 1 < args.len) {
            i += 1;
            limit = std.fmt.parseInt(usize, args[i], 10) catch 50;
        } else if (std.mem.eql(u8, a, "--scope") and i + 1 < args.len) {
            i += 1;
            scope_opt = args[i];
        } else if (std.mem.eql(u8, a, "--index") and i + 1 < args.len) {
            i += 1;
            idx_path = args[i];
        } else if (std.mem.eql(u8, a, "--root") and i + 1 < args.len) {
            i += 1;
            root_path = args[i];
        } else if (std.mem.eql(u8, a, "--out") and i + 1 < args.len) {
            i += 1;
            out_path = args[i];
        } else {
            try pos_args.append(gpa, a);
        }
    }

    if (std.mem.eql(u8, cmd, "index-status")) {
        var live = openLive(gpa, idx_path, founder_path) catch |err| {
            printErr(gpa, "index-status failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer live.deinit();
        if (json) {
            printOut(gpa, "{{\"path\":", .{});
            writeJsonStr(gpa, idx_path);
            printOut(gpa, ",\"entries\":{d},\"dirs\":{d},\"unique_names\":{d},\"bytes\":{d},\"event_id\":{d},\"synced_at\":{d}}}\n", .{
                live.base.n,
                live.base.d,
                live.base.u,
                live.base.bytes(),
                live.base.event_id,
                live.base.synced_at,
            });
        } else {
            printOut(gpa, "index: {s}\nentries: {d}\ndirs: {d}\nunique_names: {d}\nsize_bytes: {d}\nevent_id: {d}\n", .{
                idx_path,
                live.base.n,
                live.base.d,
                live.base.u,
                live.base.bytes(),
                live.base.event_id,
            });
        }
        return;
    }

    if (std.mem.eql(u8, cmd, "index-build")) {
        accel.ensureParentDir(out_path);
        if (from_founder) {
            var f = try fmt.FounderIndex.load(founder_path);
            defer f.deinit();
            try index_build.buildFromFounder(&f, out_path);
        } else {
            var scanned = try walk.scan(gpa, root_path, &.{}, 4);
            defer scanned.deinit();
            try index_build.buildFromListings(scanned.listings.items, fsevents.currentId(), query_mod.nowSecs(), home, out_path);
        }
        printOut(gpa, "built {s}\n", .{out_path});
        return;
    }

    if (std.mem.eql(u8, cmd, "search")) {
        if (pos_args.items.len == 0) {
            printErr(gpa, "usage: zigder-cli search <query...>\n", .{});
            std.process.exit(2);
        }
        const joined = try std.mem.join(gpa, " ", pos_args.items);
        defer gpa.free(joined);
        var live = openLive(gpa, idx_path, founder_path) catch |err| {
            printErr(gpa, "search failed to load index: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        defer live.deinit();
        var q = try query_mod.Query.parse(gpa, joined, home);
        defer q.deinit(gpa);
        q.limit = limit;
        if (q.scope == null) {
            if (scope_opt) |sc| q.scope = try gpa.dupe(u8, sc);
        }
        var res: search_mod.SearchResults = .{};
        defer res.deinit(gpa);
        var searcher = search_mod.Searcher.init(gpa);
        defer searcher.deinit();
        try searcher.search(gpa, &live, &q, &res);
        if (json) {
            printOut(gpa, "{{\"elapsed_us\":{d},\"tier\":{d},\"hits\":[", .{ res.elapsed_us, res.tier_used });
            for (res.hits.items, 0..) |h, hi| {
                if (hi > 0) accel.writeFd(1, ",");
                printOut(gpa, "{{\"score\":{d},\"kind\":{d},\"size\":{d},\"mtime\":{d},\"path\":", .{
                    h.score,
                    h.kind & 3,
                    h.size,
                    h.mtime,
                });
                writeJsonStr(gpa, res.pathOf(h));
                accel.writeFd(1, "}");
            }
            accel.writeFd(1, "]}\n");
        } else {
            printOut(gpa, "# {d} hits in {d} us (tier {d})\n", .{ res.hits.items.len, res.elapsed_us, res.tier_used });
            for (res.hits.items) |h| {
                printOut(gpa, "{d}\t{d}\t{s}\n", .{ h.score, h.size, res.pathOf(h) });
            }
        }
        return;
    }

    if (std.mem.eql(u8, cmd, "totals")) {
        const p = if (pos_args.items.len > 0) pos_args.items[0] else home;
        var live = try openLive(gpa, idx_path, founder_path);
        defer live.deinit();
        const tot = live.totals(p) orelse {
            printErr(gpa, "not indexed: {s}\n", .{p});
            std.process.exit(1);
        };
        if (json) {
            printOut(gpa, "{{\"bytes\":{d},\"allocated\":{d},\"items\":{d},\"visible\":{d}}}\n", .{ tot.bytes, tot.allocated, tot.items, tot.visible });
        } else {
            printOut(gpa, "bytes: {d}\nallocated: {d}\nitems: {d}\nvisible: {d}\n", .{ tot.bytes, tot.allocated, tot.items, tot.visible });
        }
        return;
    }

    if (std.mem.eql(u8, cmd, "ls")) {
        const target = if (pos_args.items.len > 0) pos_args.items[0] else home;
        var live_opt: ?live_mod.Live = openLive(gpa, idx_path, founder_path) catch null;
        defer if (live_opt) |*lv| lv.deinit();
        var totals: ?index_read.FolderTotals = if (live_opt) |*lv| (lv.folderTotals(target, gpa) catch null) else null;
        defer if (totals) |*ft| ft.deinit(gpa);
        const ft_ptr: ?*const index_read.FolderTotals = if (totals) |*ft| ft else null;
        var listing = try fs_entry.loadFolder(gpa, target, ft_ptr, .name, true, true, show_all);
        defer listing.deinit(gpa);
        if (json) {
            accel.writeFd(1, "[");
            for (listing.order.items, 0..) |eid, idx_row| {
                if (idx_row > 0) accel.writeFd(1, ",");
                const e = listing.entries.items[eid];
                accel.writeFd(1, "{\"name\":");
                writeJsonStr(gpa, listing.nameOf(e));
                printOut(gpa, ",\"dir\":{},\"size\":{d},\"mtime\":{d}}}", .{ e.isDir(), e.size, e.mtime });
            }
            accel.writeFd(1, "]\n");
        } else {
            for (listing.order.items) |eid| {
                const e = listing.entries.items[eid];
                const tag_char: u8 = if (e.isDir()) 'd' else '-';
                printOut(gpa, "{c}\t{d}\t{s}\n", .{ tag_char, e.size, listing.nameOf(e) });
            }
        }
        return;
    }

    if (std.mem.eql(u8, cmd, "info")) {
        const target = if (pos_args.items.len > 0) pos_args.items[0] else home;
        var live_opt: ?live_mod.Live = openLive(gpa, idx_path, founder_path) catch null;
        defer if (live_opt) |*lv| lv.deinit();
        const dir_totals = if (live_opt) |*lv| lv.totals(target) else null;
        const prev = quicklook.InspectorPreview.load(target, dir_totals);
        if (!prev.valid) {
            printErr(gpa, "stat failed: {s}\n", .{target});
            std.process.exit(1);
        }
        if (json) {
            accel.writeFd(1, "{\"kind\":");
            writeJsonStr(gpa, prev.kindText());
            printOut(gpa, ",\"dir\":{},\"size\":{d},\"allocated\":{d},\"mtime\":{d},\"items\":{d}}}\n", .{
                prev.is_dir,
                prev.size,
                prev.alloc,
                prev.mtime,
                prev.dir_items,
            });
        } else {
            printOut(gpa, "kind: {s}\nsize: {d}\nallocated: {d}\nitems: {d}\n", .{ prev.kindText(), prev.size, prev.alloc, prev.dir_items });
        }
        return;
    }

    try runMutatingCmd(gpa, cmd, pos_args.items);
}

fn runMutatingCmd(gpa: std.mem.Allocator, cmd: []const u8, pos: []const []const u8) !void {
    if (std.mem.eql(u8, cmd, "copy") and pos.len >= 2) {
        const out = try fs_ops.copyItem(gpa, pos[0], pos[1]);
        defer gpa.free(out);
        printOut(gpa, "{s}\n", .{out});
    } else if (std.mem.eql(u8, cmd, "move") and pos.len >= 2) {
        const out = try fs_ops.moveItem(gpa, pos[0], pos[1]);
        defer gpa.free(out);
        printOut(gpa, "{s}\n", .{out});
    } else if (std.mem.eql(u8, cmd, "duplicate") and pos.len >= 1) {
        const out = try fs_ops.duplicateItem(gpa, pos[0]);
        defer gpa.free(out);
        printOut(gpa, "{s}\n", .{out});
    } else if (std.mem.eql(u8, cmd, "trash") and pos.len >= 1) {
        const out = try fs_ops.trashItem(gpa, pos[0]);
        defer gpa.free(out);
        printOut(gpa, "{s}\n", .{out});
    } else if (std.mem.eql(u8, cmd, "delete") and pos.len >= 1) {
        try fs_ops.deleteImmediately(gpa, pos[0]);
    } else if (std.mem.eql(u8, cmd, "rename") and pos.len >= 2) {
        const out = try fs_ops.renameItem(gpa, pos[0], pos[1]);
        defer gpa.free(out);
        printOut(gpa, "{s}\n", .{out});
    } else if (std.mem.eql(u8, cmd, "new-folder") and pos.len >= 1) {
        const nm = if (pos.len >= 2) pos[1] else "untitled folder";
        const out = try fs_ops.createFolder(gpa, pos[0], nm);
        defer gpa.free(out);
        printOut(gpa, "{s}\n", .{out});
    } else if (std.mem.eql(u8, cmd, "new-file") and pos.len >= 1) {
        const nm = if (pos.len >= 2) pos[1] else "untitled";
        const out = try fs_ops.createFile(gpa, pos[0], nm);
        defer gpa.free(out);
        printOut(gpa, "{s}\n", .{out});
    } else {
        printErr(gpa, "unknown or malformed command: {s}\n", .{cmd});
        std.process.exit(2);
    }
}
