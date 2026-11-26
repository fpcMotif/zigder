const std = @import("std");
const nanoui = @import("nanoui");
const kit = nanoui.kit;
const engine_mod = @import("../index/engine.zig");
const fs_entry = @import("../fs/entry.zig");
const fs_media = @import("../fs/media.zig");
const fs_undo = @import("../fs/undo.zig");
const volumes = @import("../fs/volumes.zig");
const quicklook = @import("../fs/quicklook.zig");
const index_read = @import("../index/read.zig");
const app_sel = @import("sel.zig");
const session = @import("session.zig");

pub const ViewMode = enum { list, column, icon, gallery };

fn noopVoid(_: ?*anyopaque) void {}
fn noopStr(_: ?*anyopaque, _: []const u8) void {}
fn noopSel(_: ?*anyopaque, _: [:0]const u8) void {}

pub const Host = struct {
    ctx: ?*anyopaque = null,
    set_title: *const fn (?*anyopaque, []const u8) void = noopStr,
    redraw: *const fn (?*anyopaque) void = noopVoid,
    close: *const fn (?*anyopaque) void = noopVoid,
    open_path: *const fn (?*anyopaque, []const u8) void = noopStr,
    send_edit_action: *const fn (?*anyopaque, [:0]const u8) void = noopSel,
    interactive: bool = false,

    pub fn setTitle(h: Host, title: []const u8) void {
        h.set_title(h.ctx, title);
    }

    pub fn requestRedraw(h: Host) void {
        h.redraw(h.ctx);
    }

    pub fn requestClose(h: Host) void {
        h.close(h.ctx);
    }

    pub fn openPath(h: Host, path: []const u8) void {
        h.open_path(h.ctx, path);
    }

    pub fn sendEditAction(h: Host, sel_name: [:0]const u8) void {
        h.send_edit_action(h.ctx, sel_name);
    }
};

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
    search: session.SearchSession = .{},
    overlay: session.OverlayState = .{},
    rename: session.InlineRename = .{},
    text_focused: bool = false,
    inspector: quicklook.InspectorPreview = .{},
    inspector_path: std.ArrayList(u8) = .empty,
    undo: fs_undo.UndoStack = .{},
    media: fs_media.MediaCache,
    ql: quicklook.QuickLook,
    toaster: kit.Toaster,
    host: Host = .{},

    pub fn init(
        gpa: std.mem.Allocator,
        engine: *engine_mod.Engine,
        home: []const u8,
        initial_path: []const u8,
    ) !AppState {
        const clean_home = index_read.trimTrailingSlash(home);
        var state: AppState = .{
            .gpa = gpa,
            .home = try gpa.dupe(u8, clean_home),
            .engine = engine,
            .seen_gen = engine.status().generation,
            .sidebar = try volumes.discoverSidebar(gpa, clean_home),
            .ql = .{ .gpa = gpa, .headless = true },
            .media = fs_media.MediaCache.init(gpa),
            .toaster = .{ .gpa = gpa },
        };
        errdefer state.deinit();

        const start_path = index_read.trimTrailingSlash(initial_path);
        try state.tabs.append(gpa, try Tab.init(gpa, start_path));
        try app_sel.resetToTabFolder(&state);
        return state;
    }

    pub fn setHost(s: *AppState, host: Host) void {
        s.host = host;
        s.ql.headless = !host.interactive;
    }

    pub fn deinit(s: *AppState) void {
        s.overlay.deinit(s.gpa);
        s.rename.deinit(s.gpa);
        s.search.deinit(s.gpa);
        s.inspector_path.deinit(s.gpa);
        s.filtered_order.deinit(s.gpa);
        for (s.columns.items) |*col| col.deinit(s.gpa);
        s.columns.deinit(s.gpa);
        s.listing.deinit(s.gpa);
        for (s.tabs.items) |*t| t.deinit(s.gpa);
        s.tabs.deinit(s.gpa);
        volumes.freeSidebar(s.gpa, s.sidebar);
        s.undo.deinit(s.gpa);
        s.media.deinit();
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

    pub fn syncWithEngine(s: *AppState) void {
        const gen = s.engine.status().generation;
        if (gen != s.seen_gen) {
            s.seen_gen = gen;
            app_sel.onIndexChanged(s);
        }
    }

    pub fn selectAll(s: *AppState) void {
        const rows = s.visibleRows();
        s.tab().selected.clearRetainingCapacity();
        for (rows) |eid| s.tab().selected.put(s.gpa, eid, {}) catch {};
        s.syncQuickLook();
    }

    pub fn selectedPathsAlloc(s: *const AppState, gpa: std.mem.Allocator) ![][]u8 {
        var list: std.ArrayList([]u8) = .empty;
        errdefer {
            for (list.items) |p| gpa.free(p);
            list.deinit(gpa);
        }
        if (s.search.active()) {
            if (s.search.selectedPath()) |p| {
                const full = try gpa.dupe(u8, p);
                errdefer gpa.free(full);
                try list.append(gpa, full);
            }
            return try list.toOwnedSlice(gpa);
        }
        const cur = s.currentPath();
        for (s.visibleRows()) |eid| {
            if (!s.tabConst().selected.contains(eid)) continue;
            const nm = s.listing.nameOf(s.listing.entries.items[eid]);
            const full = try index_read.joinAlloc(gpa, cur, nm);
            errdefer gpa.free(full);
            try list.append(gpa, full);
        }
        return try list.toOwnedSlice(gpa);
    }

    pub fn syncQuickLook(s: *AppState) void {
        if (!s.ql.isVisible()) return;
        const paths = s.selectedPathsAlloc(s.gpa) catch return;
        defer index_read.freePaths(s.gpa, paths);
        s.ql.updateIfVisible(paths);
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
        var next_listing = try app_sel.loadFolder(s, clean);
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
        s.rename.cancel();
        s.tab().selected.clearRetainingCapacity();
        s.tab().cursor = 0;
        if (s.listing.order.items.len > 0) {
            s.tab().selected.put(s.gpa, s.listing.order.items[0], {}) catch {};
        }
        s.filtered_order.clearRetainingCapacity();
        if (s.view_mode == .column) app_sel.rebuildColumns(s);
        if (s.search.active()) s.search.clear();
        s.refreshInspector();
        app_sel.syncWatch(s);
        s.host.setTitle(std.fs.path.basename(clean));
    }

    pub fn navigateOrNotify(s: *AppState, raw_path: []const u8) bool {
        s.navigateTo(raw_path, true) catch {
            const clean = index_read.trimTrailingSlash(raw_path);
            const label = if (std.mem.eql(u8, clean, "/")) "Macintosh HD" else std.fs.path.basename(clean);
            s.notify(.warning, "Folder not available", label);
            return false;
        };
        return true;
    }

    pub fn fileActionsAllowed(s: *const AppState) bool {
        return !s.overlay.isOpen() and !s.text_focused;
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

    pub fn refreshInspector(s: *AppState) void {
        var buf: [2048]u8 = undefined;
        const target = blk: {
            if (s.search.active()) {
                if (s.search.selectedPath()) |p| break :blk p;
            }
            if (s.entryAtRow(s.tab().cursor)) |row| {
                break :blk index_read.joinBuf(&buf, s.currentPath(), s.listing.nameOf(row.entry)) orelse s.currentPath();
            }
            break :blk s.currentPath();
        };
        s.inspector_path.clearRetainingCapacity();
        s.inspector_path.appendSlice(s.gpa, target) catch {};
        s.inspector = quicklook.InspectorPreview.load(target, s.engine.totals(target));
        s.syncQuickLook();
    }

    pub fn setViewMode(s: *AppState, mode: ViewMode) void {
        s.view_mode = mode;
        if (mode == .column) {
            app_sel.rebuildColumns(s);
        } else if (s.columns.items.len > 0) {
            for (s.columns.items) |*col| col.deinit(s.gpa);
            s.columns.clearAndFree(s.gpa);
        }
    }

    pub fn setTagFilter(s: *AppState, bit: ?u3) void {
        s.active_tag_filter = if (s.active_tag_filter == bit) null else bit;
        s.rename.cancel();
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
        s.rename.cancelUnlessRow(row_idx);
        const anchor = s.tab().cursor;
        if (range_shift) {
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
        if (s.search.active()) {
            if (s.search.moveCursor(delta)) s.refreshInspector();
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
        const full = index_read.joinBuf(&pbuf, s.currentPath(), s.listing.nameOf(item.entry)) orelse return;
        if (item.entry.isFolderRow()) {
            _ = s.navigateOrNotify(full);
        } else {
            s.host.openPath(full);
        }
    }

    pub fn openSearchHit(s: *AppState, i: usize) void {
        const target = s.search.hitTarget(i) orelse return;
        _ = s.navigateOrNotify(target);
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
        _ = s.navigateOrNotify(parent);
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
        if (s.search.update(s.gpa, s.engine, s.home, s.currentPath())) {
            s.refreshInspector();
            app_sel.syncWatch(s);
        }
    }

    pub fn clearInlineSearch(s: *AppState) void {
        s.search.clear();
        s.refreshInspector();
        app_sel.syncWatch(s);
    }

    pub fn setSearchScope(s: *AppState, scope: session.SearchScope) void {
        s.search.setScope(scope);
        s.updateInlineSearch();
    }

    pub fn selectSearchHit(s: *AppState, idx: usize) void {
        if (s.search.selectHit(idx)) s.refreshInspector();
    }

    pub fn openModalSearch(s: *AppState, is_go: bool) void {
        if (s.overlay.openGoOrSearch(is_go, s.currentPath())) {
            app_sel.syncWatch(s);
        }
    }

    pub fn closeOverlay(s: *AppState) void {
        s.overlay.close(s.gpa);
        app_sel.syncWatch(s);
    }

    pub fn commitModalGoOrSearch(s: *AppState) void {
        const txt = std.mem.trim(u8, s.overlay.buf.text(), " \t\n");
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
        if (s.overlay.selectedHitTarget()) |target| {
            if (s.navigateOrNotify(target)) s.closeOverlay();
        }
    }

    pub fn notify(s: *AppState, status: kit.Status, title: []const u8, msg: []const u8) void {
        if (!s.host.interactive) return;
        s.toaster.push(.{ .status = status, .title = title, .message = msg });
    }
};
