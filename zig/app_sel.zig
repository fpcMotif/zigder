const std = @import("std");
const fs_entry = @import("fs_entry.zig");
const app_mod = @import("app.zig");
const AppState = app_mod.AppState;

extern "c" fn lstat(path: [*:0]const u8, buf: *std.c.Stat) c_int;

fn isDir(path: []const u8) bool {
    var buf: [2048]u8 = undefined;
    const pz = std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0) catch return false;
    var st: std.c.Stat = undefined;
    return lstat(pz, &st) == 0 and (st.mode & 0o170000) == 0o040000;
}

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

fn loadCurrent(s: *AppState) !fs_entry.FolderListing {
    return s.engine.loadFolder(s.gpa, s.currentPath(), s.sort_col, s.sort_asc, s.folders_first, s.show_hidden);
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
    return loadCurrent(s) catch |err| {
        if (isDir(s.currentPath())) return err;
        try leaveMissingFolder(s);
        return null;
    };
}

/// Loads the active tab's folder after a tab change. The selection restarts at the cursor row.
pub fn resetToTabFolder(s: *AppState) !void {
    const next = (try loadOrLeave(s)) orelse return;
    install(s, next, false);
    if (s.isSearchActive() and s.search_scope == .folder) {
        s.last_query.clearRetainingCapacity();
        s.updateInlineSearch();
    }
}

/// Reloads the folder on screen. Selection, cursor, and inline rename follow their entries by name.
pub fn reload(s: *AppState) !void {
    const next = (try loadOrLeave(s)) orelse return;
    install(s, next, std.mem.eql(u8, s.listing.path, s.currentPath()));
}

pub fn syncWatch(s: *const AppState) void {
    const search_on = s.isSearchActive() or (s.overlay == .go_or_search and !s.modal_is_go);
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
        if (s.renaming_row != null) s.renaming_row = rowOfName(s, s.rename_from.items);
    } else {
        s.renaming_row = null;
        t.cursor = clamped;
        if (rows.len > 0) t.selected.put(gpa, rows[clamped], {}) catch {};
    }
    if (s.view_mode == .column) s.rebuildColumns();
    s.refreshInspector();
    syncWatch(s);
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
        var listing = s.engine.loadFolder(gpa, pane_path, s.sort_col, s.sort_asc, s.folders_first, s.show_hidden) catch continue;
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
    const rename_eid: ?u32 = if (s.renaming_row) |r| (if (s.entryAtRow(r)) |row| row.id else null) else null;
    s.listing.resort(s.gpa, s.sort_col, s.sort_asc, s.folders_first, s.show_hidden) catch {};
    s.rebuildFiltered() catch {};
    if (cursor_eid) |eid| t.cursor = rowOfEid(s, eid) orelse 0;
    if (s.renaming_row != null) s.renaming_row = if (rename_eid) |eid| rowOfEid(s, eid) else null;
}

/// Runs when the engine's generation moves, which means the index or the disk changed under the UI.
pub fn onIndexChanged(s: *AppState) void {
    reload(s) catch {};
    if (!s.isSearchActive()) return;
    var buf: [2048]u8 = undefined;
    var kept: ?[]const u8 = null;
    const hits = s.search_results.hits.items;
    if (s.search_cursor < hits.len) {
        const p = s.search_results.pathOf(hits[s.search_cursor]);
        if (p.len <= buf.len) {
            @memcpy(buf[0..p.len], p);
            kept = buf[0..p.len];
        }
    }
    s.last_query.clearRetainingCapacity();
    s.updateInlineSearch();
    const want = kept orelse return;
    for (s.search_results.hits.items, 0..) |hit, i| {
        if (std.mem.eql(u8, s.search_results.pathOf(hit), want)) {
            s.search_cursor = i;
            s.refreshInspector();
            return;
        }
    }
}
