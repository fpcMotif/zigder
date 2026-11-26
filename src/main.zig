const std = @import("std");
const nanoui = @import("nanoui");
const engine_mod = @import("index/engine.zig");
const live_mod = @import("index/live.zig");
const walk = @import("index/walk.zig");
const app_mod = @import("app/app.zig");
const AppState = app_mod.AppState;
const menus = @import("app/menus.zig");
const view_mod = @import("ui/view.zig");
const gpu_rest = @import("ui/gpu_rest.zig");
const quicklook = @import("fs/quicklook.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const home = try nanoui.path(gpa, .home, "zigder");
    defer gpa.free(home);
    const cache_dir = try nanoui.path(gpa, .cache, "zigder");
    defer gpa.free(cache_dir);
    const zidx_path = try std.fmt.allocPrint(gpa, "{s}/index.zidx", .{cache_dir});
    defer gpa.free(zidx_path);
    const founder_path = try std.fmt.allocPrint(gpa, "{s}/Library/Application Support/Founder/fsearch/index.bin", .{home});
    defer gpa.free(founder_path);

    var initial_path: []const u8 = home;
    var saw_path = false;
    var quit_after_ms: ?u32 = null;
    if (args.len > 1) {
        for (args[1..]) |arg| {
            if (std.mem.startsWith(u8, arg, "--quit-after-ms=")) {
                quit_after_ms = std.fmt.parseInt(u32, arg["--quit-after-ms=".len..], 10) catch null;
            } else if (!saw_path and arg.len > 0 and arg[0] != '-') {
                initial_path = arg;
                saw_path = true;
            }
        }
    }

    const app = try nanoui.App.create(init, .{
        .name = "zigder",
        .quit_on_last_window_closed = true,
    });
    defer app.destroy();

    var engine = engine_mod.Engine.init(gpa);
    defer engine.deinit();
    if (app.flags.snapshot == null) quicklook.warmLastOpened(.{ .ctx = &engine, .func = wakeFromEngine });

    var state = try AppState.init(gpa, &engine, home, initial_path);
    defer state.deinit();

    if (app.flags.snapshot != null) {
        _ = engine.loadExistingSync(zidx_path);
    }

    var menu_bundle: menus.Bundle = undefined;
    menus.init(&menu_bundle, &state);
    try app.setMenu(&menu_bundle.top);
    app.onOpenFiles(&state, onOpenFiles);

    const win = try app.newWindow(.{
        .title = "zigder",
        .width = 1220,
        .height = 780,
        .min_width = 520,
        .min_height = 420,
        .title_bar = .hidden,
        .content = .{ .view = .init(&state, view_mod.view) },
    });
    if (!app.flags.hidden) state.setHost(windowHost(win));
    engine.setWaker(.{ .ctx = win, .wake = wakeWindow });
    win.on_close = .{ .ctx = &state, .func = onWindowClose };

    var idle_rest: gpu_rest.IdleRest = .{};
    if (app.flags.snapshot == null) {
        idle_rest.install(win);
        try engine.startAsync(zidx_path, founder_path, "/", home, true);
    }
    if (quit_after_ms) |ms| {
        if (ms > 0) nanoui.App.after(ms, app, onQuitTimer);
    }

    try app.run();
    idle_rest.stopped = true;
    engine.stop();
}

fn windowHost(win: *nanoui.Window) app_mod.Host {
    return .{
        .ctx = win,
        .set_title = hostSetTitle,
        .redraw = hostRedraw,
        .close = hostClose,
        .open_path = hostOpenPath,
        .send_edit_action = hostSendEditAction,
        .interactive = true,
    };
}

fn hostSetTitle(ctx: ?*anyopaque, title: []const u8) void {
    const w: *nanoui.Window = @ptrCast(@alignCast(ctx orelse return));
    w.setTitle(title);
}

fn hostRedraw(ctx: ?*anyopaque) void {
    const w: *nanoui.Window = @ptrCast(@alignCast(ctx orelse return));
    w.redraw();
}

fn hostClose(ctx: ?*anyopaque) void {
    const w: *nanoui.Window = @ptrCast(@alignCast(ctx orelse return));
    w.close();
}

fn hostOpenPath(_: ?*anyopaque, path: []const u8) void {
    _ = nanoui.shell.openPath(path);
}

fn hostSendEditAction(_: ?*anyopaque, sel_name: [:0]const u8) void {
    if (comptime nanoui.ui.portable) return;
    const objc = nanoui.objc;
    const nsapp = objc.msg(objc.Object, objc.class("NSApplication"), "sharedApplication", .{});
    _ = objc.msg(
        objc.BOOL,
        nsapp,
        "sendAction:to:from:",
        .{ objc.sel(sel_name), @as(?objc.Object, null), @as(?objc.Object, null) },
    );
}

fn wakeWindow(ctx: ?*anyopaque) void {
    const w: *nanoui.Window = @ptrCast(@alignCast(ctx orelse return));
    w.redrawFromAnyThread();
}

fn wakeFromEngine(ctx: ?*anyopaque) void {
    const e: *engine_mod.Engine = @ptrCast(@alignCast(ctx orelse return));
    e.wakeUi();
}

fn onQuitTimer(ctx: ?*anyopaque) callconv(.c) void {
    const app: *nanoui.App = @ptrCast(@alignCast(ctx orelse return));
    app.quit();
}

fn onWindowClose(ctx: *anyopaque, _: *nanoui.Window) void {
    const s: *AppState = @ptrCast(@alignCast(ctx));
    s.setHost(.{});
    s.engine.setWaker(null);
}

fn onOpenFiles(ctx: ?*anyopaque, paths: []const []const u8) void {
    const s: *AppState = @ptrCast(@alignCast(ctx orelse return));
    if (paths.len == 0) return;
    const p = paths[0];
    if (live_mod.lstatPath(p)) |st| {
        if (st.kind == walk.KIND_DIR) {
            _ = s.navigateOrNotify(p);
            s.host.requestRedraw();
            return;
        }
    }
    if (std.fs.path.dirname(p)) |dir| {
        _ = s.navigateOrNotify(dir);
    }
    s.host.requestRedraw();
}
