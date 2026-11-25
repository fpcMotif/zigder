const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const walk = @import("../index/walk.zig");
const engine_mod = @import("../index/engine.zig");
const app_mod = @import("../app/app.zig");
const session = @import("../app/session.zig");
const view_mod = @import("../ui/view.zig");
const fs_entry = @import("../fs/entry.zig");
const theme = @import("../ui/theme.zig");
const fs_media = @import("../fs/media.zig");
const fs_kind = @import("../fs/kind.zig");
const support = @import("support.zig");

fn clearSearchViaUi(t: *ui.Tester, gpa: std.mem.Allocator) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var elems: std.ArrayList(ui.access.Element) = .empty;
    try ui.access.tree(&t.ctx, arena_state.allocator(), &elems);
    for (elems.items) |el| {
        if (std.mem.eql(u8, el.label, "Clear Search")) {
            t.click(el.rect.x + el.rect.w / 2, el.rect.y + el.rect.h / 2);
            t.frame();
            t.click(400, 10);
            t.frame();
            return;
        }
    }
    return error.TextNotFound;
}

test "ui.Tester quiescence, views, sort, search, palette, folder undo, compact resize, and a11y" {
    const gpa = std.testing.allocator;
    const tmp = try support.TempDir.create("/tmp/zigder-ui");
    defer tmp.cleanup();
    const root = tmp.path();

    try support.sh(
        "mkdir -p '{s}/docs' && printf 'pub fn main() void {{}}' > '{s}/alpha.zig' && printf 'fn main() {{}}' > '{s}/beta.rs' && printf '# guide' > '{s}/docs/guide.md' && printf 'png' > '{s}/image.png'",
        .{ root, root, root, root, root },
    );

    var engine = try support.initFixtureEngine(gpa, root, "ui.zidx");
    defer engine.deinit();

    var state = try app_mod.AppState.init(gpa, &engine, root, root);
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

    const list_docs_first = findTextInBox(&t, "docs", 60, 700, 950) orelse return error.TextNotFound;
    doubleClickRect(&t, list_docs_first);
    try std.testing.expect(t.hasText("guide.md"));

    try std.testing.expect(t.shortcut(.{ .key = '[', .cmd = true }));
    t.frame();
    try std.testing.expectEqualStrings(root, state.currentPath());
    try std.testing.expect(t.hasText("alpha.zig"));

    try std.testing.expect(t.shortcut(.{ .key = 'f', .cmd = true }));
    t.frame();
    t.typeText("guide");
    t.frame();
    try std.testing.expect(state.search.results.hits.items.len >= 1);
    try std.testing.expect(t.containsText("guide.md"));
    try clearSearchViaUi(&t, gpa);

    try std.testing.expect(t.shortcut(.{ .key = 'k', .cmd = true }));
    try std.testing.expectEqual(session.OverlayKind.go_or_search, state.overlay.kind());
    try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.escape }));
    try std.testing.expectEqual(session.OverlayKind.none, state.overlay.kind());

    try std.testing.expect(t.shortcut(.{ .key = 'n', .cmd = true, .shift = true }));
    try std.testing.expectEqual(session.OverlayKind.new_folder, state.overlay.kind());
    t.frame();
    t.typeText("created_dir");
    t.key(.enter);
    t.frame();
    try std.testing.expectEqual(session.OverlayKind.none, state.overlay.kind());
    try std.testing.expect(t.hasText("created_dir"));

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
    const tmp = try support.TempDir.create("/tmp/zigder-uifx");
    defer tmp.cleanup();
    const root = tmp.path();

    try support.sh(
        "mkdir -p '{s}/docs/sub' && printf '# guide' > '{s}/docs/guide.md' && printf 'leaf' > '{s}/docs/sub/leaf.txt' && printf 'pub fn main() void {{}}' > '{s}/alpha.zig' && printf 'fn main() {{}}' > '{s}/beta.rs' && printf 'hello' > '{s}/gamma.txt' && printf 'png' > '{s}/image.png'",
        .{ root, root, root, root, root, root, root },
    );

    var engine = try support.initFixtureEngine(gpa, root, "ui.zidx");
    defer engine.deinit();

    var state = try app_mod.AppState.init(gpa, &engine, root, root);
    defer state.deinit();

    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, view_mod.view), .{ .width = 1220, .height = 780 });
    defer t.deinit();
    t.settle(0.5);

    const list_docs = findTextInBox(&t, "docs", 60, 700, 950) orelse return error.TextNotFound;
    doubleClickRect(&t, list_docs);
    try std.testing.expect(std.mem.endsWith(u8, state.currentPath(), "/docs"));
    try std.testing.expect(t.hasText("guide.md"));
    try std.testing.expect(t.shortcut(.{ .key = '[', .cmd = true }));
    t.frame();

    try std.testing.expect(t.shortcut(.{ .key = '1', .cmd = true }));
    t.settle(0.2);
    const icon_docs = findTextInBox(&t, "docs", 60, 700, 950) orelse return error.TextNotFound;
    doubleClickRect(&t, icon_docs);
    try std.testing.expect(std.mem.endsWith(u8, state.currentPath(), "/docs"));
    try std.testing.expect(t.hasText("guide.md"));
    try std.testing.expect(t.shortcut(.{ .key = '[', .cmd = true }));
    t.frame();

    try std.testing.expect(t.shortcut(.{ .key = '4', .cmd = true }));
    t.settle(0.2);
    const gallery_docs = findTextInBox(&t, "docs", 560, 730, 950) orelse return error.TextNotFound;
    doubleClickRect(&t, gallery_docs);
    try std.testing.expect(std.mem.endsWith(u8, state.currentPath(), "/docs"));
    try std.testing.expect(t.hasText("guide.md"));

    const gallery_sub = findTextInBox(&t, "sub", 560, 730, 950) orelse return error.TextNotFound;
    doubleClickRect(&t, gallery_sub);
    const crumb_docs = findTextInBox(&t, "docs", 720, 760, 950) orelse return error.TextNotFound;
    t.click(crumb_docs.x + crumb_docs.w / 2, crumb_docs.y + crumb_docs.h / 2);
    t.frame();
    try std.testing.expect(std.mem.endsWith(u8, state.currentPath(), "/docs"));
    try std.testing.expect(t.hasText("guide.md"));

    const crumb_root = findTextInBox(&t, std.fs.path.basename(root), 720, 760, 950) orelse return error.TextNotFound;
    t.click(crumb_root.x + crumb_root.w / 2, crumb_root.y + crumb_root.h / 2);
    t.frame();
    try std.testing.expect(t.shortcut(.{ .key = '2', .cmd = true }));
    t.settle(0.2);
    const row_alpha = findTextInBox(&t, "alpha.zig", 60, 700, 950) orelse return error.TextNotFound;
    t.click(row_alpha.x + row_alpha.w / 2, row_alpha.y + row_alpha.h / 2);
    t.frame();
    t.key(.enter);
    t.frame();
    t.typeText("alpha2.zig");
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

test "ui: counts group digits by thousands" {
    var buf: [26]u8 = undefined;
    try std.testing.expectEqualStrings("0", theme.fmtCountBuf(&buf, 0));
    try std.testing.expectEqualStrings("999", theme.fmtCountBuf(&buf, 999));
    try std.testing.expectEqualStrings("1,000", theme.fmtCountBuf(&buf, 1000));
    try std.testing.expectEqualStrings("2,188,690", theme.fmtCountBuf(&buf, 2_188_690));
    try std.testing.expectEqualStrings("18,446,744,073,709,551,615", theme.fmtCountBuf(&buf, std.math.maxInt(u64)));
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

test "ui: the preview pane writes dates as Finder does" {
    var buf: [64]u8 = undefined;
    const d: theme.LocalDate = .{ .year = 2026, .month = 11, .day = 2, .hour = 8, .minute = 55 };
    try std.testing.expectEqualStrings("Monday, November 2, 2026 at 08:55", theme.fmtLongDateBuf(&buf, d, 1, .h24));
    try std.testing.expectEqualStrings("Monday, November 2, 2026 at 8:55 AM", theme.fmtLongDateBuf(&buf, d, 1, .h12));
}

test "ui: PDF page turns stop at the first and last page" {
    try std.testing.expectEqual(@as(u32, 1), fs_media.pageAfter(0, 3, 1));
    try std.testing.expectEqual(@as(u32, 2), fs_media.pageAfter(2, 3, 1));
    try std.testing.expectEqual(@as(u32, 0), fs_media.pageAfter(0, 3, -1));
    try std.testing.expectEqual(@as(u32, 1), fs_media.pageAfter(2, 3, -1));
    try std.testing.expectEqual(@as(u32, 0), fs_media.pageAfter(0, 0, 1));
}

test "ui: only PDFs and pictures get a rendered preview" {
    try std.testing.expectEqual(fs_kind.PreviewKind.pdf, fs_kind.classify("Paper.PDF", walk.KIND_FILE).preview.?);
    try std.testing.expectEqual(fs_kind.PreviewKind.image, fs_kind.classify("shot.png", walk.KIND_FILE).preview.?);
    try std.testing.expect(fs_kind.classify("build.zig", walk.KIND_FILE).preview == null);
    try std.testing.expect(fs_kind.classify("LICENSE", walk.KIND_FILE).preview == null);
}

test "ui: files of one type share an icon, folders keep their own" {
    try std.testing.expectEqual(fs_media.cacheKey("/a/README.md", false), fs_media.cacheKey("/b/notes.MD", false));
    try std.testing.expect(fs_media.cacheKey("/a/build.zig", false) != fs_media.cacheKey("/a/README.md", false));
    try std.testing.expect(fs_media.cacheKey("/a/LICENSE", false) != fs_media.cacheKey("/b/LICENSE", false));
    try std.testing.expect(fs_media.cacheKey("/a/.gitignore", false) != fs_media.cacheKey("/b/.gitignore", false));
    try std.testing.expect(fs_media.cacheKey("/Users/x/Desktop", true) != fs_media.cacheKey("/Users/x/Downloads", true));
    try std.testing.expect(fs_media.cacheKey("/a/Notes.app", true) != fs_media.cacheKey("/a/Maps.app", true));
}

test "ui: macOS draws a folder and a document differently" {
    if (comptime ui.portable) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const side = 32;
    const folder = fs_media.rasterizeIcon(gpa, "/System", side) orelse return error.NoFolderIcon;
    defer gpa.free(folder);
    const document = fs_media.rasterizeIcon(gpa, "/etc/hosts", side) orelse return error.NoDocumentIcon;
    defer gpa.free(document);
    try std.testing.expectEqual(@as(usize, side * side * 4), folder.len);
    try std.testing.expect(std.mem.indexOfNone(u8, folder, &.{0}) != null);
    try std.testing.expect(!std.mem.eql(u8, folder, document));
}

test "ui: unslop Finder chrome, horizontal gallery filmstrip, single preview pane, and calm tags" {
    const gpa = std.testing.allocator;
    const tmp = try support.TempDir.create("/tmp/zigder-unslp");
    defer tmp.cleanup();
    const root = tmp.path();

    try support.sh(
        "mkdir -p '{s}/docs' && printf 'pub fn main() void {{}}' > '{s}/alpha.zig' && printf 'fn main() {{}}' > '{s}/beta.rs' && printf '# guide' > '{s}/docs/guide.md'",
        .{ root, root, root, root },
    );

    var engine = try support.initFixtureEngine(gpa, root, "ui.zidx");
    defer engine.deinit();

    var state = try app_mod.AppState.init(gpa, &engine, root, root);
    defer state.deinit();

    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, view_mod.view), .{ .width = 1220, .height = 780 });
    defer t.deinit();
    t.settle(0.5);

    try std.testing.expect(!t.containsText("indexed"));
    try std.testing.expect(!t.containsText(" free"));
    try std.testing.expect(t.hasText("Add Tags…"));

    try t.clickText("Add Tags…");
    t.frame();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var elems: std.ArrayList(ui.access.Element) = .empty;
    try ui.access.tree(&t.ctx, arena_state.allocator(), &elems);
    var found_red_checkbox = false;
    for (elems.items) |el| {
        if (el.role == .checkbox and std.mem.eql(u8, el.label, "Red")) found_red_checkbox = true;
    }
    try std.testing.expect(found_red_checkbox);

    try std.testing.expect(t.shortcut(.{ .key = '4', .cmd = true }));
    t.settle(0.2);
    const g_alpha = findTextInBox(&t, "alpha.zig", 560, 740, 930) orelse return error.TextNotFound;
    const g_beta = findTextInBox(&t, "beta.rs", 560, 740, 930) orelse return error.TextNotFound;
    try std.testing.expect(@abs(g_alpha.y - g_beta.y) < 2);
    try std.testing.expect(g_beta.x > g_alpha.x);

    try std.testing.expect(t.shortcut(.{ .key = '3', .cmd = true }));
    t.settle(0.2);
    try std.testing.expect(!t.hasText("Select an item"));

    try std.testing.expect(t.shortcut(.{ .key = '2', .cmd = true }));
    try std.testing.expect(t.shortcut(.{ .key = 't', .cmd = true }));
    t.settle(0.2);
    try std.testing.expectEqual(@as(usize, 2), state.tabs.items.len);

    try std.testing.expect(t.shortcut(.{ .key = 'f', .cmd = true }));
    t.frame();
    t.typeText("guide");
    t.frame();
    try std.testing.expect(!t.containsText("results in "));
    try clearSearchViaUi(&t, gpa);

    try std.testing.expect(t.shortcut(.{ .key = 'k', .cmd = true }));
    t.frame();
    t.typeText("guide");
    t.frame();
    try std.testing.expect(!t.containsText("results in "));
    try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.escape }));
    t.frame();
}
