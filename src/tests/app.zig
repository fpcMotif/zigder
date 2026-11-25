const std = @import("std");
const engine_mod = @import("../index/engine.zig");
const app_mod = @import("../app/app.zig");
const app_ops = @import("../app/ops.zig");
const session = @import("../app/session.zig");
const commands = @import("../app/commands.zig");
const quicklook = @import("../fs/quicklook.zig");
const support = @import("support.zig");

const Env = struct {
    tmp: support.TempDir,

    fn make() !Env {
        const tmp = try support.TempDir.create("/tmp/zigder-app");
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
        return try support.initFixtureEngine(gpa, e.root(), ".app.zidx");
    }
};

const SpyHost = struct {
    title: [128]u8 = undefined,
    title_len: usize = 0,
    opened: [256]u8 = undefined,
    opened_len: usize = 0,
    edit_action: [64]u8 = undefined,
    edit_len: usize = 0,
    redraws: usize = 0,
    closes: usize = 0,

    fn asHost(spy: *SpyHost) app_mod.Host {
        return .{
            .ctx = spy,
            .set_title = onTitle,
            .redraw = onRedraw,
            .close = onClose,
            .open_path = onOpen,
            .send_edit_action = onEdit,
            .interactive = true,
        };
    }

    fn onTitle(ctx: ?*anyopaque, title: []const u8) void {
        const spy: *SpyHost = @ptrCast(@alignCast(ctx orelse return));
        const n = @min(title.len, spy.title.len);
        @memcpy(spy.title[0..n], title[0..n]);
        spy.title_len = n;
    }

    fn onRedraw(ctx: ?*anyopaque) void {
        const spy: *SpyHost = @ptrCast(@alignCast(ctx orelse return));
        spy.redraws += 1;
    }

    fn onClose(ctx: ?*anyopaque) void {
        const spy: *SpyHost = @ptrCast(@alignCast(ctx orelse return));
        spy.closes += 1;
    }

    fn onOpen(ctx: ?*anyopaque, path: []const u8) void {
        const spy: *SpyHost = @ptrCast(@alignCast(ctx orelse return));
        const n = @min(path.len, spy.opened.len);
        @memcpy(spy.opened[0..n], path[0..n]);
        spy.opened_len = n;
    }

    fn onEdit(ctx: ?*anyopaque, sel: [:0]const u8) void {
        const spy: *SpyHost = @ptrCast(@alignCast(ctx orelse return));
        const n = @min(sel.len, spy.edit_action.len);
        @memcpy(spy.edit_action[0..n], sel[0..n]);
        spy.edit_len = n;
    }
};

test "app: Host adapter receives title on navigate and tab switch, openPath, close, redraw, and edit action" {
    const gpa = std.testing.allocator;
    const env = try Env.make();
    defer env.drop();
    var engine = try env.engine(gpa);
    defer engine.deinit();

    var state = try app_mod.AppState.init(gpa, &engine, env.root(), env.root());
    defer state.deinit();

    var spy: SpyHost = .{};
    state.setHost(spy.asHost());

    var buf: [128]u8 = undefined;
    const docs = try std.fmt.bufPrint(&buf, "{s}/docs", .{env.root()});
    try state.navigateTo(docs, true);
    try std.testing.expectEqualStrings("docs", spy.title[0..spy.title_len]);

    state.newTab();
    try state.navigateTo(env.root(), true);
    try std.testing.expectEqualStrings(std.fs.path.basename(env.root()), spy.title[0..spy.title_len]);

    state.switchTab(0);
    try std.testing.expectEqualStrings("docs", spy.title[0..spy.title_len]);

    state.activateRow(0);
    try std.testing.expect(std.mem.endsWith(u8, spy.opened[0..spy.opened_len], "/docs/guide.md"));

    state.text_focused = true;
    try std.testing.expect(!commands.dispatchFromMenu(&state, .copy));
    try std.testing.expectEqualStrings("copy:", spy.edit_action[0..spy.edit_len]);

    state.text_focused = false;
    try std.testing.expect(commands.dispatchFromMenu(&state, .reload));
    try std.testing.expectEqual(@as(usize, 1), spy.redraws);

    _ = commands.dispatch(&state, .{ .action = .close_tab_or_window });
    try std.testing.expectEqual(@as(usize, 0), spy.closes);
    _ = commands.dispatch(&state, .{ .action = .close_tab_or_window });
    try std.testing.expectEqual(@as(usize, 1), spy.closes);

    state.setHost(.{});
    _ = commands.dispatch(&state, .{ .action = .close_tab_or_window });
    try std.testing.expectEqual(@as(usize, 1), spy.closes);
}

test "app: OverlayState owns delete targets per active variant and frees cleanly on close" {
    const gpa = std.testing.allocator;
    const env = try Env.make();
    defer env.drop();
    var engine = try env.engine(gpa);
    defer engine.deinit();

    var state = try app_mod.AppState.init(gpa, &engine, env.root(), env.root());
    defer state.deinit();

    try std.testing.expectEqual(@as(?[]const []u8, null), state.overlay.deleteTargets());
    state.selectRow(0, false, false);
    try std.testing.expect(commands.dispatch(&state, .{ .action = .open_delete_modal }));
    try std.testing.expectEqual(session.OverlayKind.confirm_delete, state.overlay.kind());

    const targets = state.overlay.deleteTargets() orelse return error.MissingDeleteTargets;
    try std.testing.expectEqual(@as(usize, 1), targets.len);

    _ = state.overlay.openNewFolder();
    try std.testing.expectEqual(session.OverlayKind.confirm_delete, state.overlay.kind());

    _ = commands.dispatch(&state, .close_overlay);
    try std.testing.expectEqual(session.OverlayKind.none, state.overlay.kind());
    try std.testing.expectEqual(@as(?[]const []u8, null), state.overlay.deleteTargets());
}

test "app: InlineRename clears source name on cancel and tracks reload" {
    const gpa = std.testing.allocator;
    const env = try Env.make();
    defer env.drop();
    var engine = try env.engine(gpa);
    defer engine.deinit();

    var state = try app_mod.AppState.init(gpa, &engine, env.root(), env.root());
    defer state.deinit();

    state.selectRow(0, false, false);
    try std.testing.expect(commands.dispatch(&state, .{ .action = .begin_rename }));
    try std.testing.expect(state.rename.isActive());
    try std.testing.expect(state.rename.from.items.len > 0);

    _ = commands.dispatch(&state, .cancel_rename);
    try std.testing.expect(!state.rename.isActive());
    try std.testing.expectEqual(@as(?usize, null), state.rename.row);
    try std.testing.expectEqual(@as(usize, 0), state.rename.from.items.len);
}

test "app: SearchSession preserves highlighted hit on syncWithEngine and clears on navigate" {
    const gpa = std.testing.allocator;
    const env = try Env.make();
    defer env.drop();
    var engine = try env.engine(gpa);
    defer engine.deinit();

    var state = try app_mod.AppState.init(gpa, &engine, env.root(), env.root());
    defer state.deinit();

    state.search.buf.set("txt");
    state.updateInlineSearch();
    try std.testing.expectEqual(@as(usize, 2), state.search.results.hits.items.len);
    state.search.buf.set("txt kind:invalid");
    state.updateInlineSearch();
    try std.testing.expectEqual(@as(usize, 0), state.search.results.hits.items.len);
    state.search.buf.set("txt");
    state.updateInlineSearch();
    try std.testing.expectEqual(@as(usize, 2), state.search.results.hits.items.len);
    try std.testing.expect(commands.dispatch(&state, .{ .select_search_hit = 1 }));
    var kept_buf: [256]u8 = undefined;
    const before = state.search.selectedPath() orelse return error.MissingSelectedHit;
    @memcpy(kept_buf[0..before.len], before);

    engine.recordChange(env.root());
    state.syncWithEngine();
    try std.testing.expectEqual(engine.status().generation, state.seen_gen);
    try std.testing.expectEqualStrings(kept_buf[0..before.len], state.search.selectedPath() orelse "");

    var buf: [128]u8 = undefined;
    try state.navigateTo(try std.fmt.bufPrint(&buf, "{s}/docs", .{env.root()}), true);
    try std.testing.expect(!state.search.active());
    try std.testing.expectEqual(@as(usize, 0), state.search.results.hits.items.len);
}

test "app: setHost toggles QuickLook interactivity alongside Host" {
    const gpa = std.testing.allocator;
    const env = try Env.make();
    defer env.drop();
    var engine = try env.engine(gpa);
    defer engine.deinit();

    var state = try app_mod.AppState.init(gpa, &engine, env.root(), env.root());
    defer state.deinit();

    try std.testing.expect(state.ql.headless);
    var spy: SpyHost = .{};
    state.setHost(spy.asHost());
    try std.testing.expect(!state.ql.headless);
    state.setHost(.{});
    try std.testing.expect(state.ql.headless);
}

const SpyPanel = struct {
    visible: bool = false,
    show_calls: usize = 0,
    hide_calls: usize = 0,
    reload_calls: usize = 0,

    fn asPanel(p: *SpyPanel) quicklook.Panel {
        return .{
            .ctx = p,
            .is_visible = onIsVisible,
            .show = onShow,
            .hide = onHide,
            .reload = onReload,
        };
    }

    fn onIsVisible(ctx: ?*anyopaque, _: *const quicklook.QuickLook) bool {
        const p: *SpyPanel = @ptrCast(@alignCast(ctx orelse return false));
        return p.visible;
    }

    fn onShow(ctx: ?*anyopaque, _: *quicklook.QuickLook) void {
        const p: *SpyPanel = @ptrCast(@alignCast(ctx orelse return));
        p.visible = true;
        p.show_calls += 1;
    }

    fn onHide(ctx: ?*anyopaque, _: *quicklook.QuickLook) void {
        const p: *SpyPanel = @ptrCast(@alignCast(ctx orelse return));
        p.visible = false;
        p.hide_calls += 1;
    }

    fn onReload(ctx: ?*anyopaque, _: *quicklook.QuickLook) void {
        const p: *SpyPanel = @ptrCast(@alignCast(ctx orelse return));
        p.reload_calls += 1;
    }
};

test "app: H5 QuickLook updates targets while visible across selection, selectAll, search, and navigation, and stops when closed" {
    const gpa = std.testing.allocator;
    const env = try Env.make();
    defer env.drop();
    var engine = try env.engine(gpa);
    defer engine.deinit();

    var state = try app_mod.AppState.init(gpa, &engine, env.root(), env.root());
    defer state.deinit();

    var spy_host: SpyHost = .{};
    state.setHost(spy_host.asHost());

    var spy: SpyPanel = .{};
    state.ql.setPanel(spy.asPanel());

    state.selectRow(0, false, false);
    state.selectRow(1, false, false);
    try std.testing.expectEqual(@as(usize, 0), spy.reload_calls);

    try std.testing.expect(commands.dispatch(&state, .{ .action = .quick_look }));
    try std.testing.expect(spy.visible);
    try std.testing.expectEqual(@as(usize, 1), spy.show_calls);
    try std.testing.expectEqual(@as(usize, 1), state.ql.items.items.len);

    state.selectRow(2, false, false);
    try std.testing.expectEqual(@as(usize, 1), spy.reload_calls);
    try std.testing.expectEqual(@as(usize, 1), state.ql.items.items.len);
    try std.testing.expectEqualStrings(state.inspector_path.items, state.ql.items.items[0]);

    state.selectAll();
    try std.testing.expectEqual(@as(usize, 2), spy.reload_calls);
    try std.testing.expectEqual(state.visibleRows().len, state.ql.items.items.len);

    state.search.buf.set("txt");
    state.updateInlineSearch();
    const reloads_after_search = spy.reload_calls;
    try std.testing.expect(reloads_after_search >= 3);
    try std.testing.expect(commands.dispatch(&state, .{ .select_search_hit = 1 }));
    try std.testing.expectEqual(reloads_after_search + 1, spy.reload_calls);
    try std.testing.expectEqualStrings(state.search.selectedPath().?, state.ql.items.items[0]);

    var buf: [128]u8 = undefined;
    try state.navigateTo(try std.fmt.bufPrint(&buf, "{s}/docs", .{env.root()}), true);
    try std.testing.expect(std.mem.endsWith(u8, state.ql.items.items[0], "/docs/guide.md"));

    try std.testing.expect(commands.dispatch(&state, .{ .action = .quick_look }));
    try std.testing.expect(!spy.visible);
    try std.testing.expectEqual(@as(usize, 1), spy.hide_calls);

    const final_reloads = spy.reload_calls;
    state.selectRow(0, false, false);
    try std.testing.expectEqual(final_reloads, spy.reload_calls);
}

test "app: failed batch file op notifies interactive Host instead of failing silently" {
    const gpa = std.testing.allocator;
    const env = try Env.make();
    defer env.drop();
    var engine = try env.engine(gpa);
    defer engine.deinit();

    var state = try app_mod.AppState.init(gpa, &engine, env.root(), env.root());
    defer state.deinit();

    var spy: SpyHost = .{};
    state.setHost(spy.asHost());

    for (state.visibleRows(), 0..) |row, idx| {
        const name = state.listing.nameOf(state.listing.entries.items[row]);
        if (std.mem.eql(u8, name, "a.txt")) {
            state.selectRow(idx, false, false);
            break;
        }
    }
    try support.sh("rm -f '{s}/a.txt'", .{env.root()});
    app_ops.duplicateSelected(&state);

    try std.testing.expectEqual(@as(usize, 1), state.toaster.items.items.len);
    try std.testing.expectEqualStrings("Action failed", state.toaster.items.items[0].toast.title);
}
