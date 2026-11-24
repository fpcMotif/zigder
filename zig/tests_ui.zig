const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const walk = @import("walk.zig");
const index_build = @import("index_build.zig");
const engine_mod = @import("engine.zig");
const app_mod = @import("app.zig");
const view_mod = @import("view.zig");
const fs_entry = @import("fs_entry.zig");

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
