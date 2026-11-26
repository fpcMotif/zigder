const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const walk = @import("../index/walk.zig");
const index_read = @import("../index/read.zig");
const index_build = @import("../index/build.zig");
const engine_mod = @import("../index/engine.zig");
const live_mod = @import("../index/live.zig");
const app_mod = @import("../app/app.zig");
const app_sel = @import("../app/sel.zig");
const session = @import("../app/session.zig");
const commands = @import("../app/commands.zig");
const view_mod = @import("../ui/view.zig");
const fs_undo = @import("../fs/undo.zig");
const fsevents = @import("../index/fsevents.zig");
const search_mod = @import("../search/search.zig");
const support = @import("support.zig");

extern "c" fn usleep(usec: c_uint) c_int;

const Env = struct {
    tmp: support.TempDir,

    fn make() !Env {
        const tmp = try support.TempDir.create("/tmp/zigder-state");
        errdefer tmp.cleanup();
        try support.sh(
            "cd '{s}' && mkdir docs other && printf x > a.txt && head -c 300 /dev/zero > b.txt && head -c 20 /dev/zero > c.txt && printf g > docs/guide.md",
            .{tmp.path()},
        );
        return .{ .tmp = tmp };
    }

    fn root(e: *const Env) [:0]const u8 {
        return e.tmp.path();
    }

    fn drop(e: *const Env) void {
        e.tmp.cleanup();
    }

    fn engine(e: *const Env, gpa: std.mem.Allocator) !engine_mod.Engine {
        return support.initFixtureEngine(gpa, e.root(), ".state.zidx");
    }
};

fn rowNamed(s: *const app_mod.AppState, name: []const u8) !usize {
    for (s.visibleRows(), 0..) |eid, r| {
        if (std.mem.eql(u8, s.listing.nameOf(s.listing.entries.items[eid]), name)) return r;
    }
    return error.RowNotFound;
}

fn cursorName(s: *app_mod.AppState) ![]const u8 {
    const row = s.entryAtRow(s.tab().cursor) orelse return error.NoCursorRow;
    return s.listing.nameOf(row.entry);
}

fn selectedNamed(s: *app_mod.AppState, name: []const u8) bool {
    const r = rowNamed(s, name) catch return false;
    return s.tab().selected.contains(s.visibleRows()[r]);
}

test "state: Enclosing Folder leaves the tab on the parent path" {
    const gpa = std.testing.allocator;
    const env = try Env.make();
    defer env.drop();
    var engine = try env.engine(gpa);
    defer engine.deinit();
    var state = try app_mod.AppState.init(gpa, &engine, env.root(), env.root());
    defer state.deinit();

    var buf: [128]u8 = undefined;
    try state.navigateTo(try std.fmt.bufPrint(&buf, "{s}/docs", .{env.root()}), true);
    state.goParent();
    try std.testing.expectEqualStrings(env.root(), state.currentPath());
    try std.testing.expectEqualStrings(env.root(), state.tab().history.items[state.tab().hist_pos]);
}

test "state: closing a tab before the active tab keeps the active tab" {
    const gpa = std.testing.allocator;
    const env = try Env.make();
    defer env.drop();
    var engine = try env.engine(gpa);
    defer engine.deinit();
    var state = try app_mod.AppState.init(gpa, &engine, env.root(), env.root());
    defer state.deinit();

    var buf: [128]u8 = undefined;
    const docs = try std.fmt.bufPrint(&buf, "{s}/docs", .{env.root()});
    var buf2: [128]u8 = undefined;
    const other = try std.fmt.bufPrint(&buf2, "{s}/other", .{env.root()});
    state.newTab();
    try state.navigateTo(docs, true);
    state.newTab();
    try state.navigateTo(other, true);
    state.switchTab(1);
    try std.testing.expectEqualStrings(docs, state.currentPath());

    state.closeTab(0);
    try std.testing.expectEqualStrings(docs, state.currentPath());
    try std.testing.expectEqualStrings(docs, state.listing.path);
}

test "state: Back to a deleted folder keeps history and path in step" {
    const gpa = std.testing.allocator;
    const env = try Env.make();
    defer env.drop();
    var engine = try env.engine(gpa);
    defer engine.deinit();
    var state = try app_mod.AppState.init(gpa, &engine, env.root(), env.root());
    defer state.deinit();

    var buf: [128]u8 = undefined;
    const docs = try std.fmt.bufPrint(&buf, "{s}/docs", .{env.root()});
    var buf2: [128]u8 = undefined;
    const other = try std.fmt.bufPrint(&buf2, "{s}/other", .{env.root()});
    try state.navigateTo(docs, true);
    try state.navigateTo(other, true);
    try support.sh("rm -rf '{s}'", .{docs});

    state.goBack();
    const t = state.tab();
    try std.testing.expectEqualStrings(other, state.currentPath());
    try std.testing.expectEqualStrings(state.currentPath(), t.history.items[t.hist_pos]);
}

test "state: sorting keeps the cursor on the selected entry" {
    const gpa = std.testing.allocator;
    const env = try Env.make();
    defer env.drop();
    var engine = try env.engine(gpa);
    defer engine.deinit();
    var state = try app_mod.AppState.init(gpa, &engine, env.root(), env.root());
    defer state.deinit();

    state.selectRow(try rowNamed(&state, "a.txt"), false, false);
    state.toggleSort(.size);
    try std.testing.expect((try rowNamed(&state, "a.txt")) != (try rowNamed(&state, "b.txt")));
    try std.testing.expectEqualStrings("a.txt", try cursorName(&state));
    try std.testing.expect(selectedNamed(&state, "a.txt"));
}

test "state: a background reload keeps the selection and the cursor entry" {
    const gpa = std.testing.allocator;
    const env = try Env.make();
    defer env.drop();
    var engine = try env.engine(gpa);
    defer engine.deinit();
    var state = try app_mod.AppState.init(gpa, &engine, env.root(), env.root());
    defer state.deinit();

    state.selectRow(try rowNamed(&state, "b.txt"), false, false);
    state.selectRow(try rowNamed(&state, "c.txt"), true, false);
    try support.sh("printf n > '{s}/aa.txt'", .{env.root()});
    try app_sel.reload(&state);

    try std.testing.expectEqual(@as(u32, 2), state.tab().selected.count());
    try std.testing.expect(selectedNamed(&state, "b.txt"));
    try std.testing.expect(selectedNamed(&state, "c.txt"));
    try std.testing.expectEqualStrings("c.txt", try cursorName(&state));
}

test "state: an inline rename survives a reload and renames the same file" {
    const gpa = std.testing.allocator;
    const env = try Env.make();
    defer env.drop();
    var engine = try env.engine(gpa);
    defer engine.deinit();
    var state = try app_mod.AppState.init(gpa, &engine, env.root(), env.root());
    defer state.deinit();

    state.selectRow(try rowNamed(&state, "b.txt"), false, false);
    _ = commands.dispatch(&state, .{ .action = .begin_rename });
    try support.sh("printf n > '{s}/aa.txt'", .{env.root()});
    try app_sel.reload(&state);
    state.rename.buf.set("renamed.txt");
    _ = commands.dispatch(&state, .commit_rename);

    try std.testing.expectEqual(@as(?u64, 300), support.sizeAt("{s}/renamed.txt", .{env.root()}));
    try std.testing.expectEqual(@as(?u64, 1), support.sizeAt("{s}/aa.txt", .{env.root()}));
    try std.testing.expectEqual(@as(?u64, null), support.sizeAt("{s}/b.txt", .{env.root()}));
}

test "state: Delete Immediately removes the items the dialog was opened for" {
    const gpa = std.testing.allocator;
    const env = try Env.make();
    defer env.drop();
    var engine = try env.engine(gpa);
    defer engine.deinit();
    var state = try app_mod.AppState.init(gpa, &engine, env.root(), env.root());
    defer state.deinit();

    state.selectRow(try rowNamed(&state, "c.txt"), false, false);
    _ = commands.dispatch(&state, .{ .action = .open_delete_modal });
    try std.testing.expectEqual(session.OverlayKind.confirm_delete, state.overlay.kind());
    try support.sh("printf n > '{s}/aa.txt'", .{env.root()});
    try app_sel.reload(&state);
    _ = commands.dispatch(&state, .confirm_delete);

    try std.testing.expectEqual(@as(?u64, null), support.sizeAt("{s}/c.txt", .{env.root()}));
    try std.testing.expectEqual(@as(?u64, 300), support.sizeAt("{s}/b.txt", .{env.root()}));
    try std.testing.expectEqual(@as(?u64, 1), support.sizeAt("{s}/aa.txt", .{env.root()}));
}

test "state: a reload of a deleted folder moves the tab to the nearest folder that exists" {
    const gpa = std.testing.allocator;
    const env = try Env.make();
    defer env.drop();
    var engine = try env.engine(gpa);
    defer engine.deinit();
    var state = try app_mod.AppState.init(gpa, &engine, env.root(), env.root());
    defer state.deinit();

    var buf: [128]u8 = undefined;
    const docs = try std.fmt.bufPrint(&buf, "{s}/docs", .{env.root()});
    try state.navigateTo(docs, true);
    try support.sh("rm -rf '{s}'", .{docs});
    app_sel.reload(&state) catch {};

    try std.testing.expectEqualStrings(env.root(), state.currentPath());
    try std.testing.expectEqualStrings(env.root(), state.listing.path);
}

test "state: navigation leaves search mode" {
    const gpa = std.testing.allocator;
    const env = try Env.make();
    defer env.drop();
    var engine = try env.engine(gpa);
    defer engine.deinit();
    var state = try app_mod.AppState.init(gpa, &engine, env.root(), env.root());
    defer state.deinit();

    state.search.buf.set("guide");
    state.updateInlineSearch();
    try std.testing.expect(state.search.results.hits.items.len >= 1);
    var buf: [128]u8 = undefined;
    try state.navigateTo(try std.fmt.bufPrint(&buf, "{s}/docs", .{env.root()}), true);
    try std.testing.expect(!state.search.active());
    try std.testing.expectEqual(@as(usize, 0), state.search.results.hits.items.len);
}

test "state: in search mode a file action targets the highlighted hit" {
    const gpa = std.testing.allocator;
    const env = try Env.make();
    defer env.drop();
    var engine = try env.engine(gpa);
    defer engine.deinit();
    var state = try app_mod.AppState.init(gpa, &engine, env.root(), env.root());
    defer state.deinit();

    state.selectRow(try rowNamed(&state, "a.txt"), false, false);
    state.search.buf.set("guide");
    state.updateInlineSearch();
    try std.testing.expect(state.search.results.hits.items.len >= 1);
    const hit_path = state.search.results.pathOf(state.search.results.hits.items[state.search.cursor]);

    const paths = try state.selectedPathsAlloc(gpa);
    defer index_read.freePaths(gpa, paths);
    try std.testing.expectEqual(@as(usize, 1), paths.len);
    try std.testing.expectEqualStrings(hit_path, paths[0]);

    _ = commands.dispatch(&state, .{ .action = .begin_rename });
    try std.testing.expectEqual(@as(?usize, null), state.rename.row);
}

test "state: an open overlay is modal for other overlays" {
    const gpa = std.testing.allocator;
    const env = try Env.make();
    defer env.drop();
    var engine = try env.engine(gpa);
    defer engine.deinit();
    var state = try app_mod.AppState.init(gpa, &engine, env.root(), env.root());
    defer state.deinit();

    _ = state.overlay.openNewFolder();
    state.openModalSearch(false);
    try std.testing.expectEqual(session.OverlayKind.new_folder, state.overlay.kind());
    try std.testing.expectEqualStrings("untitled folder", state.overlay.buf.text());
}

test "state: file shortcuts do not fire while a text field has focus" {
    const gpa = std.testing.allocator;
    const env = try Env.make();
    defer env.drop();
    var engine = try env.engine(gpa);
    defer engine.deinit();
    var state = try app_mod.AppState.init(gpa, &engine, env.root(), env.root());
    defer state.deinit();

    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, view_mod.view), .{ .width = 1220, .height = 780 });
    defer t.deinit();
    t.settle(1.0);

    state.selectRow(try rowNamed(&state, "a.txt"), false, false);
    try std.testing.expect(t.shortcut(.{ .key = 'f', .cmd = true }));
    t.frame();
    try std.testing.expect(t.ctx.focus_is_text);
    _ = t.shortcut(.{ .key = 'd', .cmd = true });
    t.frame();
    try std.testing.expectEqual(@as(?u64, null), support.sizeAt("{s}/a copy.txt", .{env.root()}));

    _ = commands.dispatch(&state, .{ .action = .duplicate });
    try std.testing.expectEqual(@as(?u64, null), support.sizeAt("{s}/a copy.txt", .{env.root()}));
}

test "state: a background refresh keeps the highlighted search hit" {
    const gpa = std.testing.allocator;
    const env = try Env.make();
    defer env.drop();
    var engine = try env.engine(gpa);
    defer engine.deinit();
    var state = try app_mod.AppState.init(gpa, &engine, env.root(), env.root());
    defer state.deinit();

    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, view_mod.view), .{ .width = 1220, .height = 780 });
    defer t.deinit();
    t.settle(1.0);

    state.search.buf.set("txt");
    state.updateInlineSearch();
    try std.testing.expect(state.search.results.hits.items.len >= 3);
    state.search.cursor = 2;
    var keep: [256]u8 = undefined;
    const before = state.search.results.pathOf(state.search.results.hits.items[2]);
    @memcpy(keep[0..before.len], before);

    engine.recordChange(env.root());
    t.frame();
    const hits = state.search.results.hits.items;
    try std.testing.expect(state.search.cursor < hits.len);
    try std.testing.expectEqualStrings(keep[0..before.len], state.search.results.pathOf(hits[state.search.cursor]));
}

test "state: a file clicked in a parent column becomes the action target" {
    const gpa = std.testing.allocator;
    const env = try Env.make();
    defer env.drop();
    var engine = try env.engine(gpa);
    defer engine.deinit();
    var state = try app_mod.AppState.init(gpa, &engine, env.root(), env.root());
    defer state.deinit();

    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, view_mod.view), .{ .width = 1220, .height = 780 });
    defer t.deinit();
    var buf: [128]u8 = undefined;
    try state.navigateTo(try std.fmt.bufPrint(&buf, "{s}/docs", .{env.root()}), true);
    state.show_inspector = false;
    state.setViewMode(.column);
    t.settle(1.0);

    try t.clickText("b.txt");
    t.frame();
    const paths = try state.selectedPathsAlloc(gpa);
    defer index_read.freePaths(gpa, paths);
    try std.testing.expectEqual(@as(usize, 1), paths.len);
    try std.testing.expect(std.mem.endsWith(u8, paths[0], "/b.txt"));
    try std.testing.expect(!std.mem.endsWith(u8, paths[0], "/docs/b.txt"));
    try std.testing.expectEqual(@as(?u64, 300), support.sizeAt("{s}", .{paths[0]}));
}

test "state: a root rescan event and a dropped-event flag rebuild the index" {
    const gpa = std.testing.allocator;
    const env = try Env.make();
    defer env.drop();
    var engine = try env.engine(gpa);
    defer engine.deinit();
    var buf: [128]u8 = undefined;
    const idx_path = try std.fmt.bufPrint(&buf, "{s}/.state.zidx", .{env.root()});
    try engine.configure(idx_path, null, env.root(), env.root(), false);

    var res: search_mod.SearchResults = .{};
    defer res.deinit(gpa);
    try support.sh("printf z > '{s}/latecomer.bin'", .{env.root()});
    try engine.runSearch(gpa, env.root(), "latecomer", null, 10, &res);
    try std.testing.expectEqual(@as(usize, 0), res.hits.items.len);

    var root_path = [_]u8{'/'};
    engine.applyEvents(&.{.{ .path = &root_path, .flags = fsevents.MUST_SCAN_SUBDIRS, .id = 2 }});
    engine.waitIdle();
    try std.testing.expect(!engine.status().indexing);
    try engine.runSearch(gpa, env.root(), "latecomer", null, 10, &res);
    try std.testing.expectEqual(@as(usize, 1), res.hits.items.len);

    try support.sh("printf z > '{s}/afterdrop.bin'", .{env.root()});
    var docs_path = [_]u8{ '/', 'd', 'o', 'c', 's' };
    engine.applyEvents(&.{.{ .path = &docs_path, .flags = fsevents.KERNEL_DROPPED, .id = 3 }});
    engine.waitIdle();
    try engine.runSearch(gpa, env.root(), "afterdrop", null, 10, &res);
    try std.testing.expectEqual(@as(usize, 1), res.hits.items.len);
}

const Probe = struct {
    entered: std.atomic.Value(bool) = .init(false),
    active: std.atomic.Value(u32) = .init(0),

    fn sink(ctx: ?*anyopaque, _: []fsevents.Event) void {
        const p: *Probe = @ptrCast(@alignCast(ctx.?));
        _ = p.active.fetchAdd(1, .acq_rel);
        p.entered.store(true, .release);
        _ = usleep(300_000);
        _ = p.active.fetchSub(1, .acq_rel);
    }
};

test "state: destroying an FSEvents stream waits for the callback in flight" {
    const gpa = std.testing.allocator;
    const env = try Env.make();
    defer env.drop();

    var probe: Probe = .{};
    const st = fsevents.watch(gpa, fsevents.currentId(), 0.05, Probe.sink, &probe) catch return error.SkipZigTest;
    var tries: usize = 0;
    while (tries < 60 and !probe.entered.load(.acquire)) : (tries += 1) {
        try support.sh("touch '{s}/poke-{d}'", .{ env.root(), tries });
        _ = usleep(50_000);
    }
    const saw_event = probe.entered.load(.acquire);
    st.destroy();
    if (!saw_event) return error.SkipZigTest;
    try std.testing.expectEqual(@as(u32, 0), probe.active.load(.acquire));
}

test "state: undo of a rename does not overwrite a file created at the old name" {
    const gpa = std.testing.allocator;
    const env = try Env.make();
    defer env.drop();
    var buf: [128]u8 = undefined;
    const src = try std.fmt.bufPrint(&buf, "{s}/a.txt", .{env.root()});

    var undo: fs_undo.UndoStack = .{};
    defer undo.deinit(gpa);
    const dst = try undo.renameItem(gpa, src, "moved.txt");
    defer gpa.free(dst);
    try support.sh("printf fresh > '{s}'", .{src});

    var u = try undo.undo(gpa);
    defer u.deinit(gpa);
    try std.testing.expectEqual(fs_undo.UndoStatus.failed, u.status);
    try std.testing.expectEqual(@as(?anyerror, error.DestinationExists), u.first_err);
    try std.testing.expectEqual(@as(?u64, 5), support.sizeAt("{s}", .{src}));
    try std.testing.expectEqual(@as(?u64, 1), support.sizeAt("{s}", .{dst}));
}

test "state: undo of New Folder keeps a folder that has contents" {
    const gpa = std.testing.allocator;
    const env = try Env.make();
    defer env.drop();

    var undo: fs_undo.UndoStack = .{};
    defer undo.deinit(gpa);
    const made = try undo.createFolder(gpa, env.root(), "fresh");
    defer gpa.free(made);
    try support.sh("printf keep > '{s}/keep.txt'", .{made});

    var u = try undo.undo(gpa);
    defer u.deinit(gpa);
    try std.testing.expectEqual(fs_undo.UndoStatus.failed, u.status);
    try std.testing.expectEqual(@as(?anyerror, error.FolderNotEmpty), u.first_err);
    try std.testing.expectEqual(@as(?u64, 4), support.sizeAt("{s}/keep.txt", .{made}));
}

test "state: redo of a copy does not merge into an item created at the copy path" {
    const gpa = std.testing.allocator;
    const env = try Env.make();
    defer env.drop();
    var buf: [128]u8 = undefined;
    const src = try std.fmt.bufPrint(&buf, "{s}/b.txt", .{env.root()});

    var undo: fs_undo.UndoStack = .{};
    defer undo.deinit(gpa);
    var batch = try undo.duplicateBatch(gpa, &.{src});
    defer batch.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), batch.succeeded);
    var dup_buf: [128]u8 = undefined;
    const dup = try std.fmt.bufPrint(&dup_buf, "{s}/b copy.txt", .{env.root()});

    var u = try undo.undo(gpa);
    defer u.deinit(gpa);
    try std.testing.expectEqual(fs_undo.UndoStatus.ok, u.status);
    try support.sh("printf mine > '{s}'", .{dup});

    var r = try undo.redo(gpa);
    defer r.deinit(gpa);
    try std.testing.expectEqual(fs_undo.UndoStatus.failed, r.status);
    try std.testing.expectEqual(@as(?anyerror, error.DestinationExists), r.first_err);
    try std.testing.expectEqual(@as(?u64, 4), support.sizeAt("{s}", .{dup}));
}

test "state: the live overlay reuses the slot of a path that is removed and created again" {
    const gpa = std.testing.allocator;
    const env = try Env.make();
    defer env.drop();
    var buf: [128]u8 = undefined;
    const idx_path = try std.fmt.bufPrint(&buf, "{s}/.live.zidx", .{env.root()});
    {
        var scanned = try walk.scan(gpa, env.root(), &.{}, 2);
        defer scanned.deinit();
        try index_build.buildFromListings(scanned.listings.items, 1, 1700000000, env.root(), idx_path);
    }
    var live = try live_mod.Live.init(gpa, try index_read.Index.load(idx_path));
    defer live.deinit();

    for (0..50) |_| {
        try live.putOverlay("/docs/churn.tmp", walk.KIND_FILE, 1, 4096, 1700000001);
        live.removePath("/docs/churn.tmp");
    }
    try std.testing.expectEqual(@as(usize, 1), live.overlay_items.items.len);
    try std.testing.expect(live.entry("/docs/churn.tmp") == null);
    try live.putOverlay("/docs/churn.tmp", walk.KIND_FILE, 7, 4096, 1700000002);
    try std.testing.expectEqual(@as(u64, 7), live.entry("/docs/churn.tmp").?.size);
}
