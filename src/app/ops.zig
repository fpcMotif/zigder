const std = @import("std");
const nanoui = @import("nanoui");
const kit = nanoui.kit;
const fs_ops = @import("../fs/ops.zig");
const fs_undo = @import("../fs/undo.zig");
const index_read = @import("../index/read.zig");
const volumes = @import("../fs/volumes.zig");
const app_mod = @import("app.zig");
const app_sel = @import("sel.zig");
const AppState = app_mod.AppState;

fn recordChanged(s: *AppState, paths: []const []u8) void {
    var last: []const u8 = "";
    for (paths) |p| {
        const dir = std.fs.path.dirname(p) orelse "/";
        if (std.mem.eql(u8, dir, last)) continue;
        last = dir;
        s.engine.recordChange(dir);
    }
}

fn syncDirs(s: *AppState, dirs: []const []u8) void {
    for (dirs) |dir| s.engine.recordChange(dir);
}

fn finishBatch(s: *AppState, res: fs_undo.BatchOutcome, level: kit.Status, title: []const u8) void {
    if (res.succeeded == 0) {
        if (res.failed > 0) s.notify(.danger, "Action failed", title);
        return;
    }
    syncDirs(s, res.touched_dirs);
    app_sel.reload(s) catch {};
    if (res.failed > 0) {
        s.notify(.warning, title, "Some items could not be processed");
    } else {
        s.notify(level, title, "");
    }
}

pub fn newFolder(s: *AppState, name: []const u8) void {
    const clean = std.mem.trim(u8, name, " \t\n");
    const base = if (clean.len > 0) clean else "untitled folder";
    const created = s.undo.createFolder(s.gpa, s.currentPath(), base) catch {
        s.notify(.danger, "Could not create folder", base);
        return;
    };
    defer s.gpa.free(created);
    s.engine.recordChange(s.currentPath());
    app_sel.reload(s) catch {};
    app_sel.selectOnlyName(s, std.fs.path.basename(created));
    s.notify(.success, "Folder created", std.fs.path.basename(created));
}

pub fn duplicateSelected(s: *AppState) void {
    const paths = s.selectedPathsAlloc(s.gpa) catch return;
    defer index_read.freePaths(s.gpa, paths);
    var res = s.undo.duplicateBatch(s.gpa, paths) catch return;
    defer res.deinit(s.gpa);
    finishBatch(s, res, .success, "Duplicated");
}

pub fn trashSelected(s: *AppState) void {
    const paths = s.selectedPathsAlloc(s.gpa) catch return;
    defer index_read.freePaths(s.gpa, paths);
    var res = s.undo.trashBatch(s.gpa, paths) catch return;
    defer res.deinit(s.gpa);
    finishBatch(s, res, .neutral, "Moved to Trash");
}

pub fn openDeleteModal(s: *AppState) void {
    if (!s.fileActionsAllowed()) return;
    const targets = s.selectedPathsAlloc(s.gpa) catch return;
    if (!s.overlay.openConfirmDelete(targets)) {
        index_read.freePaths(s.gpa, targets);
    }
}

pub fn beginRename(s: *AppState) void {
    if (s.overlay.isOpen() or s.search.active()) return;
    const item = s.entryAtRow(s.tab().cursor) orelse return;
    _ = s.rename.begin(s.gpa, s.tab().cursor, s.listing.nameOf(item.entry));
}

pub fn deleteConfirmed(s: *AppState) void {
    const targets = s.overlay.deleteTargets() orelse return;
    var failed: usize = 0;
    for (targets) |p| {
        fs_ops.deleteImmediately(s.gpa, p) catch {
            failed += 1;
        };
    }
    recordChanged(s, targets);
    s.closeOverlay();
    app_sel.reload(s) catch {};
    if (failed > 0) {
        s.notify(.danger, "Some items could not be deleted", "");
    } else {
        s.notify(.warning, "Deleted immediately", "");
    }
}

pub fn commitRename(s: *AppState) void {
    const req = s.rename.finish() orelse return;
    defer s.rename.cancel();
    var pbuf: [2048]u8 = undefined;
    const src = index_read.joinBuf(&pbuf, s.currentPath(), req.old_name) orelse return;
    const dst = s.undo.renameItem(s.gpa, src, req.new_name) catch {
        s.notify(.danger, "Rename failed", req.new_name);
        return;
    };
    defer s.gpa.free(dst);
    s.engine.recordChange(s.currentPath());
    app_sel.reload(s) catch {};
    app_sel.selectOnlyName(s, std.fs.path.basename(dst));
}

pub fn copySelected(s: *AppState) void {
    const paths = s.selectedPathsAlloc(s.gpa) catch return;
    defer index_read.freePaths(s.gpa, paths);
    if (paths.len == 0) return;
    fs_ops.copyFilesToPasteboard(paths);
    s.notify(.info, "Copied to Clipboard", "");
}

pub fn pasteItems(s: *AppState) void {
    const src_paths = (nanoui.clipboard.readFiles(s.gpa) catch null) orelse return;
    defer index_read.freePaths(s.gpa, src_paths);
    var res = s.undo.pasteBatch(s.gpa, src_paths, s.currentPath()) catch return;
    defer res.deinit(s.gpa);
    finishBatch(s, res, .success, "Pasted items");
}

pub fn replay(s: *AppState, comptime is_undo: bool) void {
    const verb = if (is_undo) "undo" else "redo";
    const done = if (is_undo) "Undid" else "Redid";
    const partly = if (is_undo) "undid" else "redid";
    var res = (if (is_undo) s.undo.undo(s.gpa) else s.undo.redo(s.gpa)) catch |err| {
        s.notify(.warning, "Could not " ++ verb, @errorName(err));
        return;
    };
    defer res.deinit(s.gpa);
    if (res.status == .empty) return;
    syncDirs(s, res.touched_dirs);
    app_sel.reload(s) catch {};
    switch (res.status) {
        .empty => unreachable,
        .ok => s.notify(.info, done ++ " action", ""),
        .partial => s.notify(.warning, "Partially " ++ partly ++ " batch", "Some items could not be " ++ verb ++ "ne"),
        .failed => s.notify(.warning, "Could not " ++ verb, "The item changed after the action"),
    }
}

pub fn toggleTag(s: *AppState, bit: u3) void {
    const target = if (s.inspector_path.items.len > 0) s.inspector_path.items else s.currentPath();
    const cur = volumes.readTagMask(target);
    const next = cur ^ (@as(u8, 1) << bit);
    if (volumes.writeTagMask(target, next)) {
        app_sel.reload(s) catch {};
    }
}

pub fn toggleQuickLook(s: *AppState) void {
    if (s.ql.isVisible()) {
        s.ql.close();
        return;
    }
    const paths = s.selectedPathsAlloc(s.gpa) catch return;
    defer index_read.freePaths(s.gpa, paths);
    if (paths.len == 0) return;
    s.ql.toggle(paths);
}
