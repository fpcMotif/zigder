const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const engine_mod = @import("../index/engine.zig");
const search_mod = @import("../search/search.zig");
const index_read = @import("../index/read.zig");
const walk = @import("../index/walk.zig");

fn stepCursor(cur: usize, n: usize, delta: isize) usize {
    const want = @as(isize, @intCast(cur)) + delta;
    return @intCast(std.math.clamp(want, 0, @as(isize, @intCast(n - 1))));
}

fn hitTargetAt(results: *const search_mod.SearchResults, idx: usize) ?[]const u8 {
    if (idx >= results.hits.items.len) return null;
    const hit = results.hits.items[idx];
    const path = results.pathOf(hit);
    return if ((hit.kind & 3) == walk.KIND_DIR) path else (std.fs.path.dirname(path) orelse "/");
}

pub const SearchScope = enum { disk, folder };
pub const OverlayKind = enum { none, go_or_search, new_folder, confirm_delete };

pub const GoOrSearch = struct {
    is_go: bool,
    cursor: usize = 0,
};

pub const ActiveOverlay = union(OverlayKind) {
    none,
    go_or_search: GoOrSearch,
    new_folder,
    confirm_delete: [][]u8,
};

pub const OverlayState = struct {
    active: ActiveOverlay = .none,
    buf: ui.TextBuffer = .{},
    last_query: std.ArrayList(u8) = .empty,
    results: search_mod.SearchResults = .{},

    pub fn deinit(o: *OverlayState, gpa: std.mem.Allocator) void {
        o.close(gpa);
        o.buf.deinit();
        o.last_query.deinit(gpa);
        o.results.deinit(gpa);
    }

    pub fn kind(o: *const OverlayState) OverlayKind {
        return std.meta.activeTag(o.active);
    }

    pub fn isOpen(o: *const OverlayState) bool {
        return o.active != .none;
    }

    pub fn isQuickSearch(o: *const OverlayState) bool {
        return switch (o.active) {
            .go_or_search => |g| !g.is_go,
            .none, .new_folder, .confirm_delete => false,
        };
    }

    pub fn openGoOrSearch(o: *OverlayState, is_go: bool, cur_path: []const u8) bool {
        if (o.isOpen()) return false;
        o.active = .{ .go_or_search = .{ .is_go = is_go } };
        o.buf.set(if (is_go) cur_path else "");
        o.buf.focus();
        o.last_query.clearRetainingCapacity();
        o.results.clear();
        return true;
    }

    pub fn openNewFolder(o: *OverlayState) bool {
        if (o.isOpen()) return false;
        o.active = .new_folder;
        o.buf.set("untitled folder");
        o.buf.focus();
        return true;
    }

    pub fn openConfirmDelete(o: *OverlayState, targets: [][]u8) bool {
        if (o.isOpen() or targets.len == 0) return false;
        o.active = .{ .confirm_delete = targets };
        return true;
    }

    pub fn close(o: *OverlayState, gpa: std.mem.Allocator) void {
        switch (o.active) {
            .confirm_delete => |targets| index_read.freePaths(gpa, targets),
            .none, .go_or_search, .new_folder => {},
        }
        o.active = .none;
    }

    pub fn moveCursor(o: *OverlayState, delta: isize) void {
        switch (o.active) {
            .go_or_search => |*g| {
                const n = o.results.hits.items.len;
                if (n > 0) g.cursor = stepCursor(g.cursor, n, delta);
            },
            .none, .new_folder, .confirm_delete => {},
        }
    }

    pub fn selectHit(o: *OverlayState, idx: usize) bool {
        switch (o.active) {
            .go_or_search => |*g| {
                if (idx >= o.results.hits.items.len) return false;
                g.cursor = idx;
                return true;
            },
            .none, .new_folder, .confirm_delete => return false,
        }
    }

    pub fn updateSearch(
        o: *OverlayState,
        gpa: std.mem.Allocator,
        engine: *engine_mod.Engine,
        home: []const u8,
    ) void {
        const g = switch (o.active) {
            .go_or_search => |*v| v,
            .none, .new_folder, .confirm_delete => return,
        };
        const txt = o.buf.text();
        if (std.mem.eql(u8, txt, o.last_query.items)) return;
        o.last_query.clearRetainingCapacity();
        o.last_query.appendSlice(gpa, txt) catch {};
        if (txt.len == 0 or txt[0] == '/' or txt[0] == '~') {
            o.results.clear();
            return;
        }
        engine.runSearch(gpa, home, txt, null, 25, &o.results) catch {};
        g.cursor = 0;
    }

    pub fn selectedHitTarget(o: *const OverlayState) ?[]const u8 {
        const g = switch (o.active) {
            .go_or_search => |v| v,
            .none, .new_folder, .confirm_delete => return null,
        };
        return hitTargetAt(&o.results, g.cursor);
    }

    pub fn deleteTargets(o: *const OverlayState) ?[]const []u8 {
        return switch (o.active) {
            .confirm_delete => |targets| targets,
            .none, .go_or_search, .new_folder => null,
        };
    }
};

pub const InlineRename = struct {
    row: ?usize = null,
    from: std.ArrayList(u8) = .empty,
    buf: ui.TextBuffer = .{},

    pub fn deinit(r: *InlineRename, gpa: std.mem.Allocator) void {
        r.from.deinit(gpa);
        r.buf.deinit();
    }

    pub fn isActive(r: *const InlineRename) bool {
        return r.row != null;
    }

    pub fn isRow(r: *const InlineRename, row_idx: usize) bool {
        return r.row == row_idx;
    }

    pub fn begin(r: *InlineRename, gpa: std.mem.Allocator, row_idx: usize, name: []const u8) bool {
        r.from.clearRetainingCapacity();
        r.from.appendSlice(gpa, name) catch return false;
        r.row = row_idx;
        r.buf.set(name);
        r.buf.focus();
        return true;
    }

    pub fn cancel(r: *InlineRename) void {
        r.row = null;
        r.from.clearRetainingCapacity();
    }

    pub fn followRow(r: *InlineRename, next_row: ?usize) void {
        if (r.row == null) return;
        if (next_row) |nr| {
            r.row = nr;
        } else {
            r.cancel();
        }
    }

    pub fn cancelUnlessRow(r: *InlineRename, row_idx: usize) void {
        if (r.row) |cur| {
            if (cur != row_idx) r.cancel();
        }
    }

    pub fn finish(r: *InlineRename) ?struct { old_name: []const u8, new_name: []const u8 } {
        if (r.row == null) return null;
        r.row = null;
        const old_nm = r.from.items;
        const new_nm = std.mem.trim(u8, r.buf.text(), " \t\n");
        if (old_nm.len == 0 or new_nm.len == 0 or std.mem.eql(u8, new_nm, old_nm)) {
            r.from.clearRetainingCapacity();
            return null;
        }
        return .{ .old_name = old_nm, .new_name = new_nm };
    }
};

pub const SearchSession = struct {
    buf: ui.TextBuffer = .{},
    scope: SearchScope = .disk,
    last_query: std.ArrayList(u8) = .empty,
    results: search_mod.SearchResults = .{},
    cursor: usize = 0,

    pub fn deinit(ss: *SearchSession, gpa: std.mem.Allocator) void {
        ss.buf.deinit();
        ss.last_query.deinit(gpa);
        ss.results.deinit(gpa);
    }

    pub fn active(ss: *const SearchSession) bool {
        return ss.buf.text().len > 0;
    }

    pub fn clear(ss: *SearchSession) void {
        ss.buf.clear();
        ss.last_query.clearRetainingCapacity();
        ss.results.clear();
        ss.cursor = 0;
    }

    pub fn invalidate(ss: *SearchSession) void {
        ss.last_query.clearRetainingCapacity();
    }

    pub fn setScope(ss: *SearchSession, scope: SearchScope) void {
        ss.scope = scope;
        ss.invalidate();
    }

    pub fn update(
        ss: *SearchSession,
        gpa: std.mem.Allocator,
        engine: *engine_mod.Engine,
        home: []const u8,
        current_path: []const u8,
    ) bool {
        const txt = ss.buf.text();
        if (std.mem.eql(u8, txt, ss.last_query.items)) return false;
        ss.last_query.clearRetainingCapacity();
        ss.last_query.appendSlice(gpa, txt) catch {};
        if (txt.len == 0) {
            ss.results.clear();
            ss.cursor = 0;
            return true;
        }
        const scope: ?[]const u8 = if (ss.scope == .folder) current_path else null;
        engine.runSearch(gpa, home, txt, scope, 200, &ss.results) catch {};
        ss.cursor = 0;
        return true;
    }

    pub fn refreshPreservingPath(
        ss: *SearchSession,
        gpa: std.mem.Allocator,
        engine: *engine_mod.Engine,
        home: []const u8,
        current_path: []const u8,
    ) void {
        var buf: [2048]u8 = undefined;
        var kept: ?[]const u8 = null;
        if (ss.selectedPath()) |p| {
            if (p.len <= buf.len) {
                @memcpy(buf[0..p.len], p);
                kept = buf[0..p.len];
            }
        }
        ss.invalidate();
        _ = ss.update(gpa, engine, home, current_path);
        const want = kept orelse return;
        for (ss.results.hits.items, 0..) |hit, i| {
            if (std.mem.eql(u8, ss.results.pathOf(hit), want)) {
                ss.cursor = i;
                return;
            }
        }
    }

    pub fn moveCursor(ss: *SearchSession, delta: isize) bool {
        const n = ss.results.hits.items.len;
        if (n == 0) return false;
        ss.cursor = stepCursor(ss.cursor, n, delta);
        return true;
    }

    pub fn selectHit(ss: *SearchSession, idx: usize) bool {
        if (idx >= ss.results.hits.items.len) return false;
        ss.cursor = idx;
        return true;
    }

    pub fn selectedPath(ss: *const SearchSession) ?[]const u8 {
        if (ss.cursor >= ss.results.hits.items.len) return null;
        return ss.results.pathOf(ss.results.hits.items[ss.cursor]);
    }

    pub fn hitTarget(ss: *const SearchSession, idx: usize) ?[]const u8 {
        return hitTargetAt(&ss.results, idx);
    }
};
