const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const engine_mod = @import("engine.zig");
const fs_entry = @import("fs_entry.zig");
const fs_ops = @import("fs_ops.zig");
const volumes = @import("volumes.zig");
const search_mod = @import("search.zig");
const quicklook = @import("quicklook.zig");
const index_read = @import("index_read.zig");
const app_sel = @import("app_sel.zig");

pub const ViewMode = enum { list, column, icon, gallery };
pub const OverlayKind = enum { none, go_or_search, new_folder, confirm_delete };
pub const SearchScope = enum { disk, folder };

pub const Tab = struct {
    path: []u8,
    history: std.ArrayList([]u8) = .empty,
    hist_pos: usize = 0,
    selected: std.AutoHashMapUnmanaged(u32, void) = .empty,
    cursor: usize = 0,

    pub fn init(gpa: std.mem.Allocator, initial_path: []const u8) !Tab {
        const clean = index_read.trimTrailingSlash(initial_path);
        var tab: Tab = .{
            .path = try gpa.dupe(u8, clean),
        };
        errdefer gpa.free(tab.path);
        try tab.history.append(gpa, try gpa.dupe(u8, clean));
        return tab;
    }

    pub fn deinit(t: *Tab, gpa: std.mem.Allocator) void {
        gpa.free(t.path);
        for (t.history.items) |p| gpa.free(p);
        t.history.deinit(gpa);
        t.selected.deinit(gpa);
    }

    pub fn canBack(t: *const Tab) bool {
        return t.hist_pos > 0;
    }

    pub fn canForward(t: *const Tab) bool {
        return t.hist_pos + 1 < t.history.items.len;
    }

    pub fn pushHistory(t: *Tab, gpa: std.mem.Allocator, next_path: []const u8) !void {
        const clean = index_read.trimTrailingSlash(next_path);
        const hist_copy = try gpa.dupe(u8, clean);
        errdefer gpa.free(hist_copy);
        const path_copy = try gpa.dupe(u8, clean);
        errdefer gpa.free(path_copy);
        try t.history.ensureUnusedCapacity(gpa, 1);
        while (t.history.items.len > t.hist_pos + 1) {
            if (t.history.pop()) |old| gpa.free(old);
        }
        if (t.history.items.len >= 64) {
            gpa.free(t.history.items[0]);
            _ = t.history.orderedRemove(0);
        }
        t.history.appendAssumeCapacity(hist_copy);
        t.hist_pos = t.history.items.len - 1;
        gpa.free(t.path);
        t.path = path_copy;
    }
};

pub const ColumnPane = struct {
    path: []u8,
    listing: fs_entry.FolderListing,
    selected_row: ?usize = null,

    pub fn deinit(p: *ColumnPane, gpa: std.mem.Allocator) void {
        gpa.free(p.path);
        p.listing.deinit(gpa);
    }
};

pub const AppState = struct {
    gpa: std.mem.Allocator,
    home: []u8,
    engine: *engine_mod.Engine,
    seen_gen: u64 = 0,
    tabs: std.ArrayList(Tab) = .empty,
    active_tab: usize = 0,
    listing: fs_entry.FolderListing = .{},
    filtered_order: std.ArrayList(u32) = .empty,
    columns: std.ArrayList(ColumnPane) = .empty,
    sidebar: []volumes.SidebarItem = &.{},
    active_tag_filter: ?u3 = null,
    view_mode: ViewMode = .list,
    sort_col: fs_entry.SortCol = .name,
    sort_asc: bool = true,
    folders_first: bool = true,
    show_hidden: bool = false,
    show_sidebar: bool = true,
    show_inspector: bool = true,
    show_path_bar: bool = true,
    show_status_bar: bool = true,
    icon_zoom: f32 = 84,
    search_buf: ui.TextBuffer = .{},
    modal_buf: ui.TextBuffer = .{},
    rename_buf: ui.TextBuffer = .{},
    renaming_row: ?usize = null,
    rename_from: std.ArrayList(u8) = .empty,
    overlay: OverlayKind = .none,
    modal_is_go: bool = false,
    delete_targets: [][]u8 = &.{},
    text_focused: bool = false,
    search_scope: SearchScope = .disk,
    last_query: std.ArrayList(u8) = .empty,
    last_modal_query: std.ArrayList(u8) = .empty,
    search_results: search_mod.SearchResults = .{},
    modal_results: search_mod.SearchResults = .{},
    modal_cursor: usize = 0,
    search_cursor: usize = 0,
    inspector: quicklook.InspectorPreview = .{},
    inspector_path: std.ArrayList(u8) = .empty,
    undo: fs_ops.UndoStack = .{},
    ql: quicklook.QuickLook,
    toaster: kit.Toaster,
    window: ?*nanoui.Window = null,
    headless: bool = false,

    pub fn init(
        gpa: std.mem.Allocator,
        engine: *engine_mod.Engine,
        home: []const u8,
        initial_path: []const u8,
        headless: bool,
    ) !AppState {
        const clean_home = index_read.trimTrailingSlash(home);
        var state: AppState = .{
            .gpa = gpa,
            .home = try gpa.dupe(u8, clean_home),
            .engine = engine,
            .seen_gen = engine.generation.load(.acquire),
            .sidebar = try volumes.discoverSidebar(gpa, clean_home),
            .ql = .{ .gpa = gpa, .headless = headless },
            .toaster = .{ .gpa = gpa },
            .headless = headless,
        };
        errdefer state.deinit();

        const start_path = index_read.trimTrailingSlash(initial_path);
        try state.tabs.append(gpa, try Tab.init(gpa, start_path));
        try app_sel.resetToTabFolder(&state);
        return state;
    }

    pub fn deinit(s: *AppState) void {
        s.closeOverlay();
        s.rename_from.deinit(s.gpa);
        s.search_buf.deinit();
        s.modal_buf.deinit();
        s.rename_buf.deinit();
        s.last_query.deinit(s.gpa);
        s.last_modal_query.deinit(s.gpa);
        s.search_results.deinit(s.gpa);
        s.modal_results.deinit(s.gpa);
        s.inspector_path.deinit(s.gpa);
        s.filtered_order.deinit(s.gpa);
        for (s.columns.items) |*col| col.deinit(s.gpa);
        s.columns.deinit(s.gpa);
        s.listing.deinit(s.gpa);
        for (s.tabs.items) |*t| t.deinit(s.gpa);
        s.tabs.deinit(s.gpa);
        volumes.freeSidebar(s.gpa, s.sidebar);
        s.undo.deinit(s.gpa);
        s.ql.deinit();
        s.toaster.deinit();
        s.gpa.free(s.home);
    }

    pub fn tab(s: *AppState) *Tab {
        return &s.tabs.items[s.active_tab];
    }

    pub fn tabConst(s: *const AppState) *const Tab {
        return &s.tabs.items[s.active_tab];
    }

    pub fn currentPath(s: *const AppState) []const u8 {
        return s.tabConst().path;
    }

    pub fn visibleRows(s: *const AppState) []const u32 {
        if (s.active_tag_filter != null) return s.filtered_order.items;
        return s.listing.order.items;
    }

    pub fn isSearchActive(s: *const AppState) bool {
        return s.search_buf.text().len > 0;
    }

    pub fn entryAtRow(s: *const AppState, row_idx: usize) ?struct { id: u32, entry: fs_entry.DirEntry } {
        const rows = s.visibleRows();
        if (row_idx >= rows.len) return null;
        const eid = rows[row_idx];
        return .{ .id = eid, .entry = s.listing.entries.items[eid] };
    }

    pub fn navigateTo(s: *AppState, raw_path: []const u8, push_history: bool) !void {
        const clean = try s.gpa.dupe(u8, index_read.trimTrailingSlash(raw_path));
        defer s.gpa.free(clean);
        var next_listing = try s.engine.loadFolder(s.gpa, clean, s.sort_col, s.sort_asc, s.folders_first, s.show_hidden);
        {
            errdefer next_listing.deinit(s.gpa);
            if (push_history and !std.mem.eql(u8, s.currentPath(), clean)) {
                try s.tab().pushHistory(s.gpa, clean);
            } else {
                const path_copy = try s.gpa.dupe(u8, clean);
                s.gpa.free(s.tab().path);
                s.tab().path = path_copy;
            }
        }

        s.listing.deinit(s.gpa);
        s.listing = next_listing;
        s.active_tag_filter = null;
        s.renaming_row = null;
        s.tab().selected.clearRetainingCapacity();
        s.tab().cursor = 0;
        if (s.listing.order.items.len > 0) {
            s.tab().selected.put(s.gpa, s.listing.order.items[0], {}) catch {};
        }
        s.rebuildFiltered() catch {};
        if (s.view_mode == .column) s.rebuildColumns();
        if (s.isSearchActive()) {
            s.search_buf.clear();
            s.updateInlineSearch();
        }
        s.refreshInspector();
        app_sel.syncWatch(s);
        if (s.window) |w| w.setTitle(std.fs.path.basename(clean));
    }

    pub fn reloadCurrentFolder(s: *AppState) !void {
        return app_sel.reload(s);
    }

    pub fn fileActionsAllowed(s: *const AppState) bool {
        return s.overlay == .none and !s.text_focused;
    }

    pub fn rebuildFiltered(s: *AppState) !void {
        s.filtered_order.clearRetainingCapacity();
        const tag_bit = s.active_tag_filter orelse return;
        const mask = @as(u8, 1) << tag_bit;
        for (s.listing.order.items) |eid| {
            if ((s.listing.entries.items[eid].tag_mask & mask) != 0) {
                try s.filtered_order.append(s.gpa, eid);
            }
        }
    }

    pub fn rebuildColumns(s: *AppState) void {
        app_sel.rebuildColumns(s);
    }

    pub fn refreshInspector(s: *AppState) void {
        var buf: [2048]u8 = undefined;
        const target = blk: {
            if (s.isSearchActive()) {
                if (s.search_cursor < s.search_results.hits.items.len) {
                    break :blk s.search_results.pathOf(s.search_results.hits.items[s.search_cursor]);
                }
            }
            if (s.entryAtRow(s.tab().cursor)) |row| {
                break :blk joinBuf(&buf, s.currentPath(), s.listing.nameOf(row.entry)) orelse s.currentPath();
            }
            break :blk s.currentPath();
        };
        s.inspector_path.clearRetainingCapacity();
        s.inspector_path.appendSlice(s.gpa, target) catch {};
        s.inspector = s.engine.loadInspector(target);
    }

    pub fn setViewMode(s: *AppState, mode: ViewMode) void {
        s.view_mode = mode;
        if (mode == .column) s.rebuildColumns();
    }

    pub fn setTagFilter(s: *AppState, bit: ?u3) void {
        s.active_tag_filter = if (s.active_tag_filter == bit) null else bit;
        s.renaming_row = null;
        s.rebuildFiltered() catch {};
        s.tab().cursor = 0;
        s.tab().selected.clearRetainingCapacity();
        if (s.visibleRows().len > 0) {
            s.tab().selected.put(s.gpa, s.visibleRows()[0], {}) catch {};
        }
        s.refreshInspector();
    }

    pub fn toggleSort(s: *AppState, col: fs_entry.SortCol) void {
        if (s.sort_col == col) {
            s.sort_asc = !s.sort_asc;
        } else {
            s.sort_col = col;
            s.sort_asc = col == .name or col == .kind;
        }
        app_sel.resort(s);
    }

    pub fn selectRow(s: *AppState, row_idx: usize, toggle_cmd: bool, range_shift: bool) void {
        const rows = s.visibleRows();
        if (row_idx >= rows.len) return;
        if (s.renaming_row) |r| {
            if (r != row_idx) s.renaming_row = null;
        }
        const anchor = s.tab().cursor;
        if (range_shift and rows.len > 0) {
            const lo = @min(anchor, row_idx);
            const hi = @max(anchor, row_idx);
            s.tab().selected.clearRetainingCapacity();
            for (lo..hi + 1) |r| s.tab().selected.put(s.gpa, rows[r], {}) catch {};
        } else if (toggle_cmd) {
            const eid = rows[row_idx];
            if (s.tab().selected.remove(eid) == false) {
                s.tab().selected.put(s.gpa, eid, {}) catch {};
            }
        } else {
            s.tab().selected.clearRetainingCapacity();
            s.tab().selected.put(s.gpa, rows[row_idx], {}) catch {};
        }
        s.tab().cursor = row_idx;
        s.refreshInspector();
    }

    pub fn moveCursor(s: *AppState, delta: isize) void {
        if (s.isSearchActive()) {
            const n = s.search_results.hits.items.len;
            if (n == 0) return;
            const want: isize = @as(isize, @intCast(s.search_cursor)) + delta;
            s.search_cursor = @intCast(std.math.clamp(want, 0, @as(isize, @intCast(n - 1))));
            s.refreshInspector();
            return;
        }
        const rows = s.visibleRows();
        if (rows.len == 0) return;
        const next_i: isize = @as(isize, @intCast(s.tab().cursor)) + delta;
        const clamped: usize = @intCast(std.math.clamp(next_i, 0, @as(isize, @intCast(rows.len - 1))));
        s.selectRow(clamped, false, false);
    }

    pub fn activateRow(s: *AppState, row_idx: usize) void {
        const item = s.entryAtRow(row_idx) orelse return;
        var pbuf: [2048]u8 = undefined;
        const full = joinBuf(&pbuf, s.currentPath(), s.listing.nameOf(item.entry)) orelse return;
        if (item.entry.isFolderRow()) {
            s.navigateTo(full, true) catch {};
        } else if (!s.headless) {
            _ = nanoui.shell.openPath(full);
        }
    }

    pub fn openSearchHit(s: *AppState, i: usize) void {
        if (i >= s.search_results.hits.items.len) return;
        const hit = s.search_results.hits.items[i];
        const p = s.search_results.pathOf(hit);
        const target = if ((hit.kind & 3) == 1) p else (std.fs.path.dirname(p) orelse "/");
        s.navigateTo(target, true) catch {};
    }

    pub fn goBack(s: *AppState) void {
        if (!s.tab().canBack()) return;
        s.goHistory(s.tab().hist_pos - 1);
    }

    pub fn goForward(s: *AppState) void {
        if (!s.tab().canForward()) return;
        s.goHistory(s.tab().hist_pos + 1);
    }

    fn goHistory(s: *AppState, pos: usize) void {
        s.navigateTo(s.tab().history.items[pos], false) catch {
            s.notify(.warning, "Folder not available", std.fs.path.basename(s.tab().history.items[pos]));
            return;
        };
        s.tab().hist_pos = pos;
    }

    pub fn goParent(s: *AppState) void {
        const cur = s.currentPath();
        if (std.mem.eql(u8, cur, "/")) return;
        const parent = std.fs.path.dirname(cur) orelse "/";
        s.navigateTo(parent, true) catch {};
    }

    pub fn newTab(s: *AppState) void {
        var next = Tab.init(s.gpa, s.currentPath()) catch return;
        s.tabs.append(s.gpa, next) catch {
            next.deinit(s.gpa);
            return;
        };
        s.active_tab = s.tabs.items.len - 1;
        app_sel.resetToTabFolder(s) catch {};
    }

    pub fn closeTab(s: *AppState, idx: usize) void {
        if (s.tabs.items.len <= 1 or idx >= s.tabs.items.len) return;
        var old = s.tabs.orderedRemove(idx);
        old.deinit(s.gpa);
        if (idx < s.active_tab) {
            s.active_tab -= 1;
        } else if (s.active_tab >= s.tabs.items.len) {
            s.active_tab = s.tabs.items.len - 1;
        }
        app_sel.resetToTabFolder(s) catch {};
    }

    pub fn switchTab(s: *AppState, idx: usize) void {
        if (idx >= s.tabs.items.len or idx == s.active_tab) return;
        s.active_tab = idx;
        app_sel.resetToTabFolder(s) catch {};
    }

    pub fn updateInlineSearch(s: *AppState) void {
        const txt = s.search_buf.text();
        if (std.mem.eql(u8, txt, s.last_query.items)) return;
        s.last_query.clearRetainingCapacity();
        s.last_query.appendSlice(s.gpa, txt) catch {};
        if (txt.len == 0) {
            s.search_results.clear();
            s.search_cursor = 0;
            s.refreshInspector();
            app_sel.syncWatch(s);
            return;
        }
        const scope: ?[]const u8 = if (s.search_scope == .folder) s.currentPath() else null;
        s.engine.runSearch(s.gpa, s.home, txt, scope, 200, &s.search_results) catch {};
        s.search_cursor = 0;
        s.refreshInspector();
        app_sel.syncWatch(s);
    }

    pub fn openModalSearch(s: *AppState, is_go: bool) void {
        if (s.overlay != .none) return;
        s.overlay = .go_or_search;
        s.modal_is_go = is_go;
        s.modal_cursor = 0;
        s.modal_buf.set(if (is_go) s.currentPath() else "");
        s.modal_buf.focus();
        s.last_modal_query.clearRetainingCapacity();
        s.modal_results.clear();
        app_sel.syncWatch(s);
    }

    pub fn openNewFolderModal(s: *AppState) void {
        if (s.overlay != .none) return;
        s.overlay = .new_folder;
        s.modal_buf.set("untitled folder");
        s.modal_buf.focus();
    }

    pub fn openDeleteModal(s: *AppState) void {
        if (!s.fileActionsAllowed()) return;
        const targets = s.selectedPathsAlloc(s.gpa) catch return;
        if (targets.len == 0) {
            s.gpa.free(targets);
            return;
        }
        s.delete_targets = targets;
        s.overlay = .confirm_delete;
    }

    pub fn closeOverlay(s: *AppState) void {
        s.overlay = .none;
        if (s.delete_targets.len > 0) fs_ops.freePaths(s.gpa, s.delete_targets);
        s.delete_targets = &.{};
        app_sel.syncWatch(s);
    }

    pub fn updateModalSearch(s: *AppState) void {
        const txt = s.modal_buf.text();
        if (std.mem.eql(u8, txt, s.last_modal_query.items)) return;
        s.last_modal_query.clearRetainingCapacity();
        s.last_modal_query.appendSlice(s.gpa, txt) catch {};
        if (txt.len == 0 or txt[0] == '/' or txt[0] == '~') {
            s.modal_results.clear();
            return;
        }
        s.engine.runSearch(s.gpa, s.home, txt, null, 25, &s.modal_results) catch {};
        s.modal_cursor = 0;
    }

    pub fn commitModalGoOrSearch(s: *AppState) void {
        const txt = std.mem.trim(u8, s.modal_buf.text(), " \t\n");
        if (txt.len > 0 and (txt[0] == '/' or txt[0] == '~')) {
            var expanded_buf: [2048]u8 = undefined;
            const target = if (txt[0] == '~')
                std.fmt.bufPrint(&expanded_buf, "{s}{s}", .{ s.home, txt[1..] }) catch txt
            else
                txt;
            s.navigateTo(target, true) catch {
                s.notify(.warning, "Path not found", target);
                return;
            };
            s.closeOverlay();
            return;
        }
        if (s.modal_cursor < s.modal_results.hits.items.len) {
            const hit = s.modal_results.hits.items[s.modal_cursor];
            const path = s.modal_results.pathOf(hit);
            const target = if ((hit.kind & 3) == 1) path else (std.fs.path.dirname(path) orelse "/");
            s.navigateTo(target, true) catch {};
            s.closeOverlay();
        }
    }

    pub fn selectedPathsAlloc(s: *const AppState, gpa: std.mem.Allocator) ![][]u8 {
        return @import("app_ops.zig").selectedPathsAlloc(s, gpa);
    }

    pub fn actionNewFolder(s: *AppState, name: []const u8) void {
        @import("app_ops.zig").newFolder(s, name);
    }

    pub fn actionDuplicate(s: *AppState) void {
        if (s.fileActionsAllowed()) @import("app_ops.zig").duplicateSelected(s);
    }

    pub fn actionTrash(s: *AppState) void {
        if (s.fileActionsAllowed()) @import("app_ops.zig").trashSelected(s);
    }

    pub fn actionDeleteConfirmed(s: *AppState) void {
        @import("app_ops.zig").deleteConfirmed(s);
    }

    pub fn actionBeginRename(s: *AppState) void {
        if (s.overlay != .none or s.isSearchActive()) return;
        const item = s.entryAtRow(s.tab().cursor) orelse return;
        const name = s.listing.nameOf(item.entry);
        s.rename_from.clearRetainingCapacity();
        s.rename_from.appendSlice(s.gpa, name) catch return;
        s.renaming_row = s.tab().cursor;
        s.rename_buf.set(name);
        s.rename_buf.focus();
    }

    pub fn actionCommitRename(s: *AppState) void {
        @import("app_ops.zig").commitRename(s);
    }

    pub fn actionCopy(s: *AppState) void {
        if (s.fileActionsAllowed()) @import("app_ops.zig").copySelected(s);
    }

    pub fn actionPaste(s: *AppState) void {
        if (s.fileActionsAllowed()) @import("app_ops.zig").pasteItems(s);
    }

    pub fn actionUndo(s: *AppState) void {
        if (s.fileActionsAllowed()) @import("app_ops.zig").undoAction(s);
    }

    pub fn actionRedo(s: *AppState) void {
        if (s.fileActionsAllowed()) @import("app_ops.zig").redoAction(s);
    }

    pub fn actionToggleTag(s: *AppState, bit: u3) void {
        @import("app_ops.zig").toggleTag(s, bit);
    }

    pub fn actionQuickLook(s: *AppState) void {
        if (s.fileActionsAllowed()) @import("app_ops.zig").toggleQuickLook(s);
    }

    pub fn notify(s: *AppState, status: kit.Status, title: []const u8, msg: []const u8) void {
        if (s.headless) return;
        s.toaster.push(.{ .status = status, .title = title, .message = msg });
    }
};

pub fn joinBuf(buf: []u8, dir: []const u8, name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, dir, "/")) {
        if (1 + name.len > buf.len) return null;
        buf[0] = '/';
        @memcpy(buf[1 .. 1 + name.len], name);
        return buf[0 .. 1 + name.len];
    }
    if (dir.len + 1 + name.len > buf.len) return null;
    @memcpy(buf[0..dir.len], dir);
    buf[dir.len] = '/';
    @memcpy(buf[dir.len + 1 ..][0..name.len], name);
    return buf[0 .. dir.len + 1 + name.len];
}
