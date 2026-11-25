const std = @import("std");
const index_read = @import("../index/read.zig");
const live_mod = @import("../index/live.zig");
const walk = @import("../index/walk.zig");
const fs_entry = @import("../fs/entry.zig");
const app_mod = @import("app.zig");
const AppState = app_mod.AppState;

pub fn rowOfEid(s: *const AppState, eid: u32) ?usize {
    for (s.visibleRows(), 0..) |e, r| {
        if (e == eid) return r;
    }
    return null;
}

pub fn rowOfName(s: *const AppState, name: []const u8) ?usize {
    for (s.visibleRows(), 0..) |eid, r| {
        if (std.mem.eql(u8, s.listing.nameOf(s.listing.entries.items[eid]), name)) return r;
    }
    return null;
}

pub fn selectOnlyName(s: *AppState, name: []const u8) void {
    const r = rowOfName(s, name) orelse return;
    const t = s.tab();
    t.selected.clearRetainingCapacity();
    t.selected.put(s.gpa, s.visibleRows()[r], {}) catch {};
    t.cursor = r;
    s.refreshInspector();
}

pub fn loadFolder(s: *AppState, path: []const u8) !fs_entry.FolderListing {
    var totals = s.engine.folderTotals(s.gpa, path) catch null;
    defer if (totals) |*ft| ft.deinit(s.gpa);
    const ft_ptr: ?*const index_read.FolderTotals = if (totals) |*ft| ft else null;
    return fs_entry.loadFolder(s.gpa, path, ft_ptr, s.sort_col, s.sort_asc, s.folders_first, s.show_hidden);
}

fn leaveMissingFolder(s: *AppState) !void {
    var buf: [2048]u8 = undefined;
    const cur = s.currentPath();
    if (cur.len > buf.len) return error.OpenDirFailed;
    @memcpy(buf[0..cur.len], cur);
    var p: []const u8 = buf[0..cur.len];
    while (!std.mem.eql(u8, p, "/")) {
        p = std.fs.path.dirname(p) orelse "/";
        if (s.navigateTo(p, true)) |_| {
            s.notify(.warning, "Folder no longer exists", std.fs.path.basename(buf[0..cur.len]));
            return;
        } else |_| {}
    }
    return error.OpenDirFailed;
}

fn loadOrLeave(s: *AppState) !?fs_entry.FolderListing {
    return loadFolder(s, s.currentPath()) catch |err| {
        if (live_mod.lstatPath(s.currentPath())) |st| {
            if (st.kind == walk.KIND_DIR) return err;
        }
        try leaveMissingFolder(s);
        return null;
    };
}

/// Loads the active tab's folder after a tab change. The selection restarts at the cursor row.
pub fn resetToTabFolder(s: *AppState) !void {
    const next = (try loadOrLeave(s)) orelse return;
    install(s, next, false);
    if (s.search.active() and s.search.scope == .folder) {
        s.search.invalidate();
        s.updateInlineSearch();
    }
}

/// Reloads the folder on screen. Selection, cursor, and inline rename follow their entries by name.
pub fn reload(s: *AppState) !void {
    const next = (try loadOrLeave(s)) orelse return;
    install(s, next, std.mem.eql(u8, s.listing.path, s.currentPath()));
}

pub fn syncWatch(s: *const AppState) void {
    const search_on = s.search.active() or s.overlay.isQuickSearch();
    s.engine.setUiWatch(s.currentPath(), search_on);
}

fn install(s: *AppState, next: fs_entry.FolderListing, keep: bool) void {
    const gpa = s.gpa;
    const t = s.tab();
    var old = s.listing;
    defer old.deinit(gpa);

    var wanted: std.StringHashMapUnmanaged(void) = .empty;
    defer wanted.deinit(gpa);
    var cursor_name: ?[]const u8 = null;
    if (keep) {
        if (s.entryAtRow(t.cursor)) |row| cursor_name = old.nameOf(row.entry);
        var it = t.selected.keyIterator();
        while (it.next()) |eid| {
            if (eid.* >= old.entries.items.len) continue;
            wanted.put(gpa, old.nameOf(old.entries.items[eid.*]), {}) catch {};
        }
    }

    s.listing = next;
    t.selected.clearRetainingCapacity();
    s.rebuildFiltered() catch {};
    const rows = s.visibleRows();
    const clamped = if (rows.len == 0) 0 else @min(t.cursor, rows.len - 1);
    if (keep) {
        for (rows) |eid| {
            const nm = s.listing.nameOf(s.listing.entries.items[eid]);
            if (wanted.contains(nm)) t.selected.put(gpa, eid, {}) catch {};
        }
        t.cursor = if (cursor_name) |cn| rowOfName(s, cn) orelse clamped else clamped;
        if (s.rename.isActive()) s.rename.followRow(rowOfName(s, s.rename.from.items));
    } else {
        s.rename.cancel();
        t.cursor = clamped;
        if (rows.len > 0) t.selected.put(gpa, rows[clamped], {}) catch {};
    }
    if (s.view_mode == .column) rebuildColumns(s);
    s.refreshInspector();
    syncWatch(s);
    if (!keep) s.host.setTitle(std.fs.path.basename(s.currentPath()));
}

pub fn rebuildColumns(s: *AppState) void {
    const gpa = s.gpa;
    for (s.columns.items) |*col| col.deinit(gpa);
    s.columns.clearRetainingCapacity();

    var chain: [4][]const u8 = undefined;
    var count: usize = 0;
    var p = s.currentPath();
    while (count < chain.len) {
        chain[count] = p;
        count += 1;
        if (std.mem.eql(u8, p, "/") or std.mem.eql(u8, p, s.home)) break;
        p = std.fs.path.dirname(p) orelse "/";
    }
    var i = count;
    while (i > 0) {
        i -= 1;
        const pane_path = chain[i];
        var listing = loadFolder(s, pane_path) catch continue;
        var sel: ?usize = null;
        if (i > 0) {
            const next_nm = std.fs.path.basename(chain[i - 1]);
            for (listing.order.items, 0..) |eid, r| {
                if (std.mem.eql(u8, listing.nameOf(listing.entries.items[eid]), next_nm)) {
                    sel = r;
                    break;
                }
            }
        } else if (listing.order.items.len > 0) {
            sel = @min(s.tab().cursor, listing.order.items.len - 1);
        }
        const path_copy = gpa.dupe(u8, pane_path) catch {
            listing.deinit(gpa);
            continue;
        };
        s.columns.append(gpa, .{ .path = path_copy, .listing = listing, .selected_row = sel }) catch {
            gpa.free(path_copy);
            listing.deinit(gpa);
        };
    }
}

pub fn resort(s: *AppState) void {
    const t = s.tab();
    const cursor_eid: ?u32 = if (s.entryAtRow(t.cursor)) |row| row.id else null;
    const rename_eid: ?u32 = if (s.rename.row) |r| (if (s.entryAtRow(r)) |row| row.id else null) else null;
    s.listing.resort(s.gpa, s.sort_col, s.sort_asc, s.folders_first, s.show_hidden) catch {};
    s.rebuildFiltered() catch {};
    if (cursor_eid) |eid| t.cursor = rowOfEid(s, eid) orelse 0;
    if (s.rename.isActive()) s.rename.followRow(if (rename_eid) |eid| rowOfEid(s, eid) else null);
    s.syncQuickLook();
}

/// Runs when the engine's generation moves, which means the index or the disk changed under the UI.
pub fn onIndexChanged(s: *AppState) void {
    reload(s) catch {};
    if (!s.search.active()) return;
    s.search.refreshPreservingPath(s.gpa, s.engine, s.home, s.currentPath());
    s.refreshInspector();
}
