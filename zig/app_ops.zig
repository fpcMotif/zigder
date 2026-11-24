const std = @import("std");
const fs_ops = @import("fs_ops.zig");
const volumes = @import("volumes.zig");
const app_mod = @import("app.zig");
const app_sel = @import("app_sel.zig");
const AppState = app_mod.AppState;

pub fn selectedPathsAlloc(s: *const AppState, gpa: std.mem.Allocator) ![][]u8 {
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |p| gpa.free(p);
        list.deinit(gpa);
    }
    if (s.isSearchActive()) {
        const hits = s.search_results.hits.items;
        if (s.search_cursor < hits.len) {
            const full = try gpa.dupe(u8, s.search_results.pathOf(hits[s.search_cursor]));
            errdefer gpa.free(full);
            try list.append(gpa, full);
        }
        return try list.toOwnedSlice(gpa);
    }
    const cur = s.currentPath();
    for (s.visibleRows()) |eid| {
        if (!s.tabConst().selected.contains(eid)) continue;
        const nm = s.listing.nameOf(s.listing.entries.items[eid]);
        const full = if (std.mem.eql(u8, cur, "/"))
            try std.fmt.allocPrint(gpa, "/{s}", .{nm})
        else
            try std.fmt.allocPrint(gpa, "{s}/{s}", .{ cur, nm });
        errdefer gpa.free(full);
        try list.append(gpa, full);
    }
    return try list.toOwnedSlice(gpa);
}

fn recordChanged(s: *AppState, paths: []const []u8) void {
    var last: []const u8 = "";
    for (paths) |p| {
        const dir = std.fs.path.dirname(p) orelse "/";
        if (std.mem.eql(u8, dir, last)) continue;
        last = dir;
        s.engine.recordChange(dir);
    }
}

pub fn newFolder(s: *AppState, name: []const u8) void {
    const clean = std.mem.trim(u8, name, " \t\n");
    const base = if (clean.len > 0) clean else "untitled folder";
    const created = fs_ops.createFolder(s.gpa, s.currentPath(), base) catch {
        s.notify(.danger, "Could not create folder", base);
        return;
    };
    defer s.gpa.free(created);
    s.undo.record(s.gpa, .create, "dir", created) catch {};
    s.engine.recordChange(s.currentPath());
    s.reloadCurrentFolder() catch {};
    app_sel.selectOnlyName(s, std.fs.path.basename(created));
    s.notify(.success, "Folder created", std.fs.path.basename(created));
}

pub fn duplicateSelected(s: *AppState) void {
    const paths = selectedPathsAlloc(s, s.gpa) catch return;
    defer fs_ops.freePaths(s.gpa, paths);
    var count: usize = 0;
    for (paths) |p| {
        const dst = fs_ops.duplicateItem(s.gpa, p) catch continue;
        defer s.gpa.free(dst);
        s.undo.record(s.gpa, .copy, p, dst) catch {};
        count += 1;
    }
    if (count > 0) {
        recordChanged(s, paths);
        s.reloadCurrentFolder() catch {};
        s.notify(.success, "Duplicated", "");
    }
}

pub fn trashSelected(s: *AppState) void {
    const paths = selectedPathsAlloc(s, s.gpa) catch return;
    defer fs_ops.freePaths(s.gpa, paths);
    var count: usize = 0;
    for (paths) |p| {
        const trashed = fs_ops.trashItem(s.gpa, p) catch continue;
        defer s.gpa.free(trashed);
        s.undo.record(s.gpa, .trash, p, trashed) catch {};
        count += 1;
    }
    if (count > 0) {
        recordChanged(s, paths);
        s.reloadCurrentFolder() catch {};
        s.notify(.neutral, "Moved to Trash", "");
    }
}

pub fn deleteConfirmed(s: *AppState) void {
    if (s.overlay != .confirm_delete) return;
    var failed: usize = 0;
    for (s.delete_targets) |p| {
        fs_ops.deleteImmediately(s.gpa, p) catch {
            failed += 1;
        };
    }
    recordChanged(s, s.delete_targets);
    s.closeOverlay();
    s.reloadCurrentFolder() catch {};
    if (failed > 0) {
        s.notify(.danger, "Some items could not be deleted", "");
    } else {
        s.notify(.warning, "Deleted immediately", "");
    }
}

pub fn commitRename(s: *AppState) void {
    if (s.renaming_row == null) return;
    s.renaming_row = null;
    const old_nm = s.rename_from.items;
    const new_nm = std.mem.trim(u8, s.rename_buf.text(), " \t\n");
    if (old_nm.len == 0 or new_nm.len == 0 or std.mem.eql(u8, new_nm, old_nm)) return;
    var pbuf: [2048]u8 = undefined;
    const src = app_mod.joinBuf(&pbuf, s.currentPath(), old_nm) orelse return;
    const dst = fs_ops.renameItem(s.gpa, src, new_nm) catch {
        s.notify(.danger, "Rename failed", new_nm);
        return;
    };
    defer s.gpa.free(dst);
    s.undo.record(s.gpa, .rename, src, dst) catch {};
    s.engine.recordChange(s.currentPath());
    s.reloadCurrentFolder() catch {};
    app_sel.selectOnlyName(s, std.fs.path.basename(dst));
}

pub fn copySelected(s: *AppState) void {
    const paths = selectedPathsAlloc(s, s.gpa) catch return;
    defer fs_ops.freePaths(s.gpa, paths);
    if (paths.len == 0) return;
    var slices = s.gpa.alloc([]const u8, paths.len) catch return;
    defer s.gpa.free(slices);
    for (paths, 0..) |p, i| slices[i] = p;
    fs_ops.copyFilesToPasteboard(slices);
    s.notify(.info, "Copied to Clipboard", "");
}

pub fn pasteItems(s: *AppState) void {
    const src_paths = (fs_ops.readFilesFromPasteboard(s.gpa) catch null) orelse return;
    defer fs_ops.freePaths(s.gpa, src_paths);
    var count: usize = 0;
    for (src_paths) |sp| {
        const dst = fs_ops.copyItem(s.gpa, sp, s.currentPath()) catch continue;
        defer s.gpa.free(dst);
        s.undo.record(s.gpa, .copy, sp, dst) catch {};
        count += 1;
    }
    if (count > 0) {
        s.engine.recordChange(s.currentPath());
        s.reloadCurrentFolder() catch {};
        s.notify(.success, "Pasted items", "");
    }
}

pub fn undoAction(s: *AppState) void {
    const had = s.undo.undo_list.items.len > 0;
    const ok = s.undo.undo(s.gpa) catch false;
    if (!ok and had) s.notify(.warning, "Could not undo", "The item changed after the action");
    if (!had) return;
    s.engine.recordChange(s.currentPath());
    s.reloadCurrentFolder() catch {};
    if (ok) s.notify(.info, "Undid action", "");
}

pub fn redoAction(s: *AppState) void {
    const had = s.undo.redo_list.items.len > 0;
    const ok = s.undo.redo(s.gpa) catch false;
    if (!ok and had) s.notify(.warning, "Could not redo", "The item changed after the action");
    if (!had) return;
    s.engine.recordChange(s.currentPath());
    s.reloadCurrentFolder() catch {};
    if (ok) s.notify(.info, "Redid action", "");
}

pub fn toggleTag(s: *AppState, bit: u3) void {
    const target = if (s.inspector_path.items.len > 0) s.inspector_path.items else s.currentPath();
    const cur = volumes.readTagMask(target);
    const next = cur ^ (@as(u8, 1) << bit);
    if (volumes.writeTagMask(target, next)) {
        s.reloadCurrentFolder() catch {};
    }
}

pub fn toggleQuickLook(s: *AppState) void {
    const paths = selectedPathsAlloc(s, s.gpa) catch return;
    defer fs_ops.freePaths(s.gpa, paths);
    if (paths.len == 0) return;
    var slices = s.gpa.alloc([]const u8, paths.len) catch return;
    defer s.gpa.free(slices);
    for (paths, 0..) |p, i| slices[i] = p;
    s.ql.toggle(slices);
}
