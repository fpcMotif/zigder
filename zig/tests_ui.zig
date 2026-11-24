const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const walk = @import("walk.zig");
const index_build = @import("index_build.zig");
const engine_mod = @import("engine.zig");
const app_mod = @import("app.zig");
const view_mod = @import("view.zig");
const fs_entry = @import("fs_entry.zig");
const theme = @import("theme.zig");
const file_icons = @import("file_icons.zig");

extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
extern "c" fn system(cmd: [*:0]const u8) c_int;

test "ui.Tester quiescence, views, sort, search, palette, folder undo, compact resize, and a11y" {
    const gpa = std.testing.allocator;
    var tmp: [64:0]u8 = @splat(0);
    const tmpl = "/tmp/zigder-ui-XXXXXX";
    @memcpy(tmp[0..tmpl.len], tmpl);
    _ = mkdtemp(&tmp) orelse return error.TmpDir;
    const root = tmp[0..tmpl.len :0];
    defer {
        var cmd: [128]u8 = undefined;
        const s = std.fmt.bufPrintSentinel(&cmd, "rm -rf '{s}'", .{root}, 0) catch unreachable;
        _ = system(s);
    }

    var cmd_buf: [512]u8 = undefined;
    const setup = try std.fmt.bufPrintSentinel(
        &cmd_buf,
        "mkdir -p '{s}/docs' && printf 'pub fn main() void {{}}' > '{s}/alpha.zig' && printf 'fn main() {{}}' > '{s}/beta.rs' && printf '# guide' > '{s}/docs/guide.md' && printf 'png' > '{s}/image.png'",
        .{ root, root, root, root, root },
        0,
    );
    try std.testing.expectEqual(@as(c_int, 0), system(setup));

    var idx_buf: [128]u8 = undefined;
    const idx_path = try std.fmt.bufPrint(&idx_buf, "{s}/ui.zidx", .{root});
    {
        var scanned = try walk.scan(gpa, root, &.{}, 2);
        defer scanned.deinit();
        try index_build.buildFromListings(scanned.listings.items, 1, 1700000000, root, idx_path);
    }

    var engine = try engine_mod.Engine.initHeadlessWithIndex(gpa, idx_path);
    defer engine.deinit();

    var state = try app_mod.AppState.init(gpa, &engine, root, root, true);
    defer state.deinit();

    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, view_mod.view), .{ .width = 1220, .height = 780 });
    defer t.deinit();

    t.settle(2.0);
    try std.testing.expect(!t.ctx.animating);
    try std.testing.expect(t.ctx.frame_in == null);

    try std.testing.expect(t.hasText("alpha.zig"));
    try std.testing.expect(t.hasText("beta.rs"));
    try std.testing.expect(t.hasText("docs"));

    try t.clickText("Size");
    try std.testing.expectEqual(fs_entry.SortCol.size, state.sort_col);
    try std.testing.expect(!state.sort_asc);
    try t.clickText("Name");
    try std.testing.expectEqual(fs_entry.SortCol.name, state.sort_col);

    try std.testing.expect(t.shortcut(.{ .key = '3', .cmd = true }));
    t.settle(0.5);
    try std.testing.expectEqual(app_mod.ViewMode.column, state.view_mode);
    try std.testing.expect(t.hasText("alpha.zig"));

    try std.testing.expect(t.shortcut(.{ .key = '1', .cmd = true }));
    t.settle(0.5);
    try std.testing.expectEqual(app_mod.ViewMode.icon, state.view_mode);
    try std.testing.expect(t.hasText("alpha.zig"));

    try std.testing.expect(t.shortcut(.{ .key = '4', .cmd = true }));
    t.settle(0.5);
    try std.testing.expectEqual(app_mod.ViewMode.gallery, state.view_mode);
    try std.testing.expect(t.hasText("alpha.zig"));

    try std.testing.expect(t.shortcut(.{ .key = '2', .cmd = true }));
    t.settle(0.5);
    try std.testing.expectEqual(app_mod.ViewMode.list, state.view_mode);

    var docs_buf: [256]u8 = undefined;
    const docs_path = try std.fmt.bufPrint(&docs_buf, "{s}/docs", .{root});
    try state.navigateTo(docs_path, true);
    t.frame();
    try std.testing.expect(t.hasText("guide.md"));

    try std.testing.expect(t.shortcut(.{ .key = '[', .cmd = true }));
    t.frame();
    try std.testing.expectEqualStrings(root, state.currentPath());
    try std.testing.expect(t.hasText("alpha.zig"));

    try std.testing.expect(t.shortcut(.{ .key = 'f', .cmd = true }));
    t.frame();
    t.typeText("guide");
    t.frame();
    try std.testing.expect(state.search_results.hits.items.len >= 1);
    try std.testing.expect(t.containsText("guide.md"));
    state.search_buf.clear();
    state.updateInlineSearch();
    t.ctx.focus = 0;
    t.frame();

    try std.testing.expect(t.shortcut(.{ .key = 'k', .cmd = true }));
    try std.testing.expectEqual(app_mod.OverlayKind.go_or_search, state.overlay);
    try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.escape }));
    try std.testing.expectEqual(app_mod.OverlayKind.none, state.overlay);

    try std.testing.expect(t.shortcut(.{ .key = 'n', .cmd = true, .shift = true }));
    try std.testing.expectEqual(app_mod.OverlayKind.new_folder, state.overlay);
    t.frame();
    t.typeText("created_dir");
    t.key(.enter);
    t.frame();
    try std.testing.expectEqual(app_mod.OverlayKind.none, state.overlay);
    try std.testing.expect(t.hasText("created_dir"));

    t.ctx.focus = 0;
    t.frame();
    try std.testing.expect(t.shortcut(.{ .key = 'z', .cmd = true }));
    t.frame();
    try std.testing.expect(!t.hasText("created_dir"));

    t.resize(560, 760);
    t.settle(0.5);
    try std.testing.expect(t.hasText("alpha.zig"));
    const compact_px = try t.render(gpa);
    defer compact_px.deinit(gpa);
    try std.testing.expect(compact_px.width > 0);
    try std.testing.expect(compact_px.height > 0);

    t.resize(1220, 780);
    t.settle(0.5);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var elems: std.ArrayList(ui.access.Element) = .empty;
    try ui.access.tree(&t.ctx, arena_state.allocator(), &elems);
    var found_sb = false;
    var found_back = false;
    var found_list = false;
    var found_insp = false;
    for (elems.items) |el| {
        if (std.mem.eql(u8, el.label, "Toggle Sidebar")) found_sb = true;
        if (std.mem.eql(u8, el.label, "Back")) found_back = true;
        if (std.mem.eql(u8, el.label, "List View")) found_list = true;
        if (std.mem.eql(u8, el.label, "Toggle Inspector")) found_insp = true;
    }
    try std.testing.expect(found_sb);
    try std.testing.expect(found_back);
    try std.testing.expect(found_list);
    try std.testing.expect(found_insp);
}

fn findTextInBox(t: *ui.Tester, text: []const u8, min_y: f32, max_y: f32, max_x: f32) ?ui.Rect {
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, text) and n.rect.x < max_x and n.rect.y >= min_y and n.rect.y <= max_y) return n.rect,
        .icon, .image, .texture, .hole, .canvas, .none => {},
    };
    return null;
}

fn doubleClickRect(t: *ui.Tester, r: ui.Rect) void {
    t.doubleClick(r.x + r.w / 2, r.y + r.h / 2);
    t.frame();
}

test "ui.Tester double-click enters folder in list, icon, gallery, inline rename, and path bar breadcrumb" {
    const gpa = std.testing.allocator;
    var tmp: [64:0]u8 = @splat(0);
    const tmpl = "/tmp/zigder-uifx-XXXXXX";
    @memcpy(tmp[0..tmpl.len], tmpl);
    _ = mkdtemp(&tmp) orelse return error.TmpDir;
    const root = tmp[0..tmpl.len :0];
    defer {
        var cmd: [128]u8 = undefined;
        const s = std.fmt.bufPrintSentinel(&cmd, "rm -rf '{s}'", .{root}, 0) catch unreachable;
        _ = system(s);
    }

    var cmd_buf: [640]u8 = undefined;
    const setup = try std.fmt.bufPrintSentinel(
        &cmd_buf,
        "mkdir -p '{s}/docs/sub' && printf '# guide' > '{s}/docs/guide.md' && printf 'leaf' > '{s}/docs/sub/leaf.txt' && printf 'pub fn main() void {{}}' > '{s}/alpha.zig' && printf 'fn main() {{}}' > '{s}/beta.rs' && printf 'hello' > '{s}/gamma.txt' && printf 'png' > '{s}/image.png'",
        .{ root, root, root, root, root, root, root },
        0,
    );
    try std.testing.expectEqual(@as(c_int, 0), system(setup));

    var idx_buf: [128]u8 = undefined;
    const idx_path = try std.fmt.bufPrint(&idx_buf, "{s}/ui.zidx", .{root});
    {
        var scanned = try walk.scan(gpa, root, &.{}, 2);
        defer scanned.deinit();
        try index_build.buildFromListings(scanned.listings.items, 1, 1700000000, root, idx_path);
    }

    var engine = try engine_mod.Engine.initHeadlessWithIndex(gpa, idx_path);
    defer engine.deinit();

    var state = try app_mod.AppState.init(gpa, &engine, root, root, true);
    defer state.deinit();

    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, view_mod.view), .{ .width = 1220, .height = 780 });
    defer t.deinit();
    t.settle(0.5);

    const list_docs = findTextInBox(&t, "docs", 60, 700, 950) orelse return error.TextNotFound;
    doubleClickRect(&t, list_docs);
    try std.testing.expect(std.mem.endsWith(u8, state.currentPath(), "/docs"));
    try std.testing.expect(t.hasText("guide.md"));
    state.goBack();
    t.frame();

    try std.testing.expect(t.shortcut(.{ .key = '1', .cmd = true }));
    t.settle(0.2);
    const icon_docs = findTextInBox(&t, "docs", 60, 700, 950) orelse return error.TextNotFound;
    doubleClickRect(&t, icon_docs);
    try std.testing.expect(std.mem.endsWith(u8, state.currentPath(), "/docs"));
    try std.testing.expect(t.hasText("guide.md"));
    state.goBack();
    t.frame();

    try std.testing.expect(t.shortcut(.{ .key = '4', .cmd = true }));
    t.settle(0.2);
    const gallery_docs = findTextInBox(&t, "docs", 560, 730, 950) orelse return error.TextNotFound;
    doubleClickRect(&t, gallery_docs);
    try std.testing.expect(std.mem.endsWith(u8, state.currentPath(), "/docs"));
    try std.testing.expect(t.hasText("guide.md"));

    var sub_buf: [256]u8 = undefined;
    const sub_path = try std.fmt.bufPrint(&sub_buf, "{s}/docs/sub", .{root});
    try state.navigateTo(sub_path, true);
    t.frame();
    const crumb_docs = findTextInBox(&t, "docs", 720, 760, 950) orelse return error.TextNotFound;
    t.click(crumb_docs.x + crumb_docs.w / 2, crumb_docs.y + crumb_docs.h / 2);
    t.frame();
    try std.testing.expect(std.mem.endsWith(u8, state.currentPath(), "/docs"));
    try std.testing.expect(t.hasText("guide.md"));

    try state.navigateTo(root, true);
    try std.testing.expect(t.shortcut(.{ .key = '2', .cmd = true }));
    t.settle(0.2);
    state.selectRow(1, false, false);
    state.actionBeginRename();
    state.rename_buf.set("alpha2.zig");
    t.frame();
    t.key(.enter);
    t.frame();
    try std.testing.expect(t.hasText("alpha2.zig"));
    try std.testing.expect(!t.hasText("alpha.zig"));
}

test "ui: sizes read as Finder writes them" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Zero bytes", theme.fmtBytesBuf(&buf, 0));
    try std.testing.expectEqualStrings("1 byte", theme.fmtBytesBuf(&buf, 1));
    try std.testing.expectEqualStrings("545 bytes", theme.fmtBytesBuf(&buf, 545));
    try std.testing.expectEqualStrings("464 KB", theme.fmtBytesBuf(&buf, 463_600));
    try std.testing.expectEqualStrings("2.6 MB", theme.fmtBytesBuf(&buf, 2_600_000));
    try std.testing.expectEqualStrings("1.41 GB", theme.fmtBytesBuf(&buf, 1_410_000_000));
    try std.testing.expectEqualStrings("205.7 GB", theme.fmtBytesBuf(&buf, 205_700_000_000));
}

test "ui: dates read as Finder writes them" {
    var buf: [48]u8 = undefined;
    const d: theme.LocalDate = .{ .year = 2026, .month = 11, .day = 24, .hour = 3, .minute = 6 };
    try std.testing.expectEqualStrings("Nov 24, 2026 at 3:06 AM", theme.fmtDateBuf(&buf, d, 5, .h12));
    try std.testing.expectEqualStrings("Yesterday at 3:06 AM", theme.fmtDateBuf(&buf, d, 1, .h12));
    try std.testing.expectEqualStrings("Today at 3:06 AM", theme.fmtDateBuf(&buf, d, 0, .h12));
    const noon: theme.LocalDate = .{ .year = 2026, .month = 1, .day = 2, .hour = 12, .minute = 0 };
    try std.testing.expectEqualStrings("Jan 2, 2026 at 12:00 PM", theme.fmtDateBuf(&buf, noon, 300, .h12));
    const midnight: theme.LocalDate = .{ .year = 2026, .month = 1, .day = 2, .hour = 0, .minute = 30 };
    try std.testing.expectEqualStrings("Today at 12:30 AM", theme.fmtDateBuf(&buf, midnight, 0, .h12));
    const evening: theme.LocalDate = .{ .year = 2026, .month = 1, .day = 2, .hour = 23, .minute = 5 };
    try std.testing.expectEqualStrings("Today at 11:05 PM", theme.fmtDateBuf(&buf, evening, 0, .h12));
    const morning: theme.LocalDate = .{ .year = 2026, .month = 11, .day = 25, .hour = 9, .minute = 5 };
    try std.testing.expectEqualStrings("Today at 09:05", theme.fmtDateBuf(&buf, morning, 0, .h24));
    const afternoon: theme.LocalDate = .{ .year = 2026, .month = 11, .day = 24, .hour = 13, .minute = 49 };
    try std.testing.expectEqualStrings("Yesterday at 13:49", theme.fmtDateBuf(&buf, afternoon, 1, .h24));
    try std.testing.expectEqualStrings("Nov 21, 2026 at 13:49", theme.fmtDateBuf(&buf, .{ .year = 2026, .month = 11, .day = 21, .hour = 13, .minute = 49 }, 4, .h24));
}

test "ui: files of one type share an icon, folders keep their own" {
    try std.testing.expectEqual(file_icons.cacheKey("/a/README.md", false), file_icons.cacheKey("/b/notes.MD", false));
    try std.testing.expect(file_icons.cacheKey("/a/build.zig", false) != file_icons.cacheKey("/a/README.md", false));
    try std.testing.expect(file_icons.cacheKey("/a/LICENSE", false) != file_icons.cacheKey("/b/LICENSE", false));
    try std.testing.expect(file_icons.cacheKey("/a/.gitignore", false) != file_icons.cacheKey("/b/.gitignore", false));
    try std.testing.expect(file_icons.cacheKey("/Users/x/Desktop", true) != file_icons.cacheKey("/Users/x/Downloads", true));
    try std.testing.expect(file_icons.cacheKey("/a/Notes.app", true) != file_icons.cacheKey("/a/Maps.app", true));
}

test "ui: macOS draws a folder and a document differently" {
    if (comptime ui.portable) return error.SkipZigTest;
    const side = 32;
    const folder = file_icons.rasterize("/System", side) orelse return error.NoFolderIcon;
    defer std.heap.smp_allocator.free(folder);
    const document = file_icons.rasterize("/etc/hosts", side) orelse return error.NoDocumentIcon;
    defer std.heap.smp_allocator.free(document);
    try std.testing.expectEqual(@as(usize, side * side * 4), folder.len);
    try std.testing.expect(std.mem.indexOfNone(u8, folder, &.{0}) != null);
    try std.testing.expect(!std.mem.eql(u8, folder, document));
}
