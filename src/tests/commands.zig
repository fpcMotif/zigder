const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const engine_mod = @import("../index/engine.zig");
const app_mod = @import("../app/app.zig");
const session = @import("../app/session.zig");
const menus = @import("../app/menus.zig");
const commands = @import("../app/commands.zig");
const view_mod = @import("../ui/view.zig");
const volumes = @import("../fs/volumes.zig");
const support = @import("support.zig");

const Env = struct {
    tmp: support.TempDir,

    fn make() !Env {
        const tmp = try support.TempDir.create("/tmp/zigder-cmd");
        errdefer tmp.cleanup();
        try support.sh(
            "cd '{s}' && mkdir docs other && printf x > a.txt && printf y > b.txt && printf g > docs/guide.md",
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
        return support.initFixtureEngine(gpa, e.root(), ".cmd.zidx");
    }
};

fn findTextInBox(t: *ui.Tester, text: []const u8, min_y: f32, max_y: f32, min_x: f32, max_x: f32) ?ui.Rect {
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, text) and n.rect.x >= min_x and n.rect.x < max_x and n.rect.y >= min_y and n.rect.y <= max_y) return n.rect,
        .icon, .image, .texture, .hole, .canvas, .none => {},
    };
    return null;
}

test "commands: menu dispatch enforces overlay modal guard" {
    const gpa = std.testing.allocator;
    const env = try Env.make();
    defer env.drop();
    var engine = try env.engine(gpa);
    defer engine.deinit();
    var state = try app_mod.AppState.init(gpa, &engine, env.root(), env.root());
    defer state.deinit();

    _ = state.overlay.openNewFolder();
    try std.testing.expectEqual(session.OverlayKind.new_folder, state.overlay.kind());

    const blocked = [_]commands.ActionId{
        .new_tab,
        .select_all,
        .view_icon,
        .toggle_sidebar,
        .toggle_hidden,
        .go_home,
        .focus_search,
    };
    for (blocked) |id| {
        try std.testing.expect(!commands.dispatchFromMenu(&state, id));
    }

    try std.testing.expectEqual(@as(usize, 1), state.tabs.items.len);
    try std.testing.expectEqual(app_mod.ViewMode.list, state.view_mode);
    try std.testing.expect(state.show_sidebar);
    try std.testing.expect(!state.show_hidden);
    try std.testing.expectEqualStrings(env.root(), state.currentPath());
    try std.testing.expectEqual(session.OverlayKind.new_folder, state.overlay.kind());
}

test "commands: menu file actions do not fire while a text field has focus" {
    const gpa = std.testing.allocator;
    const env = try Env.make();
    defer env.drop();
    var engine = try env.engine(gpa);
    defer engine.deinit();
    var state = try app_mod.AppState.init(gpa, &engine, env.root(), env.root());
    defer state.deinit();

    state.selectRow(1, false, false);
    const sel_before = state.tab().selected.count();
    state.text_focused = true;

    const blocked = [_]commands.ActionId{
        .select_all,
        .duplicate,
        .trash,
        .copy,
        .paste,
        .undo,
        .redo,
    };
    for (blocked) |id| {
        try std.testing.expect(!commands.dispatchFromMenu(&state, id));
    }

    try std.testing.expectEqual(sel_before, state.tab().selected.count());
    try std.testing.expectEqual(@as(?u64, null), support.sizeAt("{s}/a copy.txt", .{env.root()}));
    try std.testing.expectEqual(@as(?u64, null), support.sizeAt("{s}/b copy.txt", .{env.root()}));
}

test "commands: unified catalog builds native menus and matches shortcuts" {
    const gpa = std.testing.allocator;
    const env = try Env.make();
    defer env.drop();
    var engine = try env.engine(gpa);
    defer engine.deinit();
    var state = try app_mod.AppState.init(gpa, &engine, env.root(), env.root());
    defer state.deinit();

    var bundle: menus.Bundle = undefined;
    menus.init(&bundle, &state);
    inline for (commands.catalog) |spec| {
        try std.testing.expect(spec.label.len > 0);
    }

    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, view_mod.view), .{ .width = 1220, .height = 780 });
    defer t.deinit();
    t.settle(0.5);

    var buf: [128]u8 = undefined;
    const docs_path = try std.fmt.bufPrint(&buf, "{s}/docs", .{env.root()});
    try state.navigateTo(docs_path, true);
    t.frame();

    try std.testing.expect(t.shortcut(.{ .key = 'h', .cmd = true, .shift = true }));
    try std.testing.expectEqualStrings(env.root(), state.currentPath());

    const zoom0 = state.icon_zoom;
    try std.testing.expect(t.shortcut(.{ .key = '=', .cmd = true }));
    try std.testing.expect(state.icon_zoom > zoom0);
    try std.testing.expect(t.shortcut(.{ .key = '-', .cmd = true }));
    try std.testing.expectEqual(zoom0, state.icon_zoom);

    try support.sh("printf r > '{s}/reloaded.txt'", .{env.root()});
    try std.testing.expect(t.shortcut(.{ .key = 'r', .cmd = true }));
    try std.testing.expect(t.hasText("reloaded.txt"));

    try std.testing.expect(t.shortcut(.{ .key = 't', .cmd = true }));
    try std.testing.expectEqual(@as(usize, 2), state.tabs.items.len);
    try std.testing.expect(t.shortcut(.{ .key = 'w', .cmd = true }));
    try std.testing.expectEqual(@as(usize, 1), state.tabs.items.len);
    try std.testing.expect(t.shortcut(.{ .key = 'w', .cmd = true }));
    try std.testing.expectEqual(@as(usize, 1), state.tabs.items.len);
}

test "commands: FIFO queue copies path and name payloads by value" {
    const gpa = std.testing.allocator;
    const env = try Env.make();
    defer env.drop();
    var engine = try env.engine(gpa);
    defer engine.deinit();
    var state = try app_mod.AppState.init(gpa, &engine, env.root(), env.root());
    defer state.deinit();

    var q: commands.Queue = .{};
    var path_buf: [128]u8 = undefined;
    const docs_slice = try std.fmt.bufPrint(&path_buf, "{s}/docs", .{env.root()});
    var name_buf: [32]u8 = undefined;
    @memcpy(name_buf[0..8], "guide.md");

    q.push(.{ .navigate_to = docs_slice });
    q.push(.{ .select_only_name = name_buf[0..8] });

    @memset(&path_buf, 'X');
    @memset(&name_buf, 'Y');

    try std.testing.expect(q.flush(&state));
    try std.testing.expect(std.mem.endsWith(u8, state.currentPath(), "/docs"));
    const cur = state.entryAtRow(state.tab().cursor) orelse return error.NoCursorRow;
    try std.testing.expectEqualStrings("guide.md", state.listing.nameOf(cur.entry));
}

test "commands: for-loop clicks in tab strip, sidebar tags, and inspector tags mutate safely" {
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
    t.settle(0.5);

    try std.testing.expect(t.shortcut(.{ .key = 't', .cmd = true }));
    var buf: [128]u8 = undefined;
    const docs_path = try std.fmt.bufPrint(&buf, "{s}/docs", .{env.root()});
    try state.navigateTo(docs_path, true);
    t.frame();
    try std.testing.expectEqual(@as(usize, 1), state.active_tab);

    const root_base = std.fs.path.basename(env.root());
    const tab_pill = findTextInBox(&t, root_base, 50, 86, 200, 950) orelse return error.TabPillNotFound;
    t.click(tab_pill.x + tab_pill.w / 2, tab_pill.y + tab_pill.h / 2);
    t.frame();
    try std.testing.expectEqual(@as(usize, 0), state.active_tab);
    try std.testing.expectEqualStrings(env.root(), state.currentPath());

    try t.clickText("Red");
    try std.testing.expectEqual(@as(?u3, 0), state.active_tag_filter);
    try t.clickText("Red");
    try std.testing.expectEqual(@as(?u3, null), state.active_tag_filter);

    try t.clickText("Add Tags…");
    const tags_hdr = findTextInBox(&t, "Tags", 100, 750, 880, 1220) orelse return error.TagsHeaderNotFound;
    t.click(tags_hdr.x + 11, tags_hdr.y + tags_hdr.h + 18);
    t.frame();
    try std.testing.expect((volumes.readTagMask(state.inspector_path.items) & 1) != 0);
}
