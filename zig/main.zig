const std = @import("std");
const nanoui = @import("nanoui");
const engine_mod = @import("engine.zig");
const AppState = @import("app.zig").AppState;
const menus = @import("menus.zig");
const view_mod = @import("view.zig");
const gpu_rest = @import("gpu_rest.zig");

extern "c" fn lstat(path: [*:0]const u8, buf: *std.c.Stat) c_int;

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

    var state = try AppState.init(gpa, &engine, home, initial_path, app.flags.hidden);
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
    state.window = win;
    engine.setWaker(win);
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

fn onQuitTimer(ctx: ?*anyopaque) callconv(.c) void {
    const app: *nanoui.App = @ptrCast(@alignCast(ctx orelse return));
    app.quit();
}

fn onWindowClose(ctx: *anyopaque, _: *nanoui.Window) void {
    const s: *AppState = @ptrCast(@alignCast(ctx));
    s.window = null;
    s.engine.setWaker(null);
}

fn onOpenFiles(ctx: ?*anyopaque, paths: []const []const u8) void {
    const s: *AppState = @ptrCast(@alignCast(ctx orelse return));
    if (paths.len == 0) return;
    const p = paths[0];
    var pbuf: [2048]u8 = undefined;
    const pz = std.fmt.bufPrintSentinel(&pbuf, "{s}", .{p}, 0) catch return;
    var st: std.c.Stat = undefined;
    if (lstat(pz, &st) == 0 and (st.mode & 0o170000) == 0o040000) {
        s.navigateTo(p, true) catch {};
    } else if (std.fs.path.dirname(p)) |dir| {
        s.navigateTo(dir, true) catch {};
    }
    if (s.window) |w| w.redraw();
}
