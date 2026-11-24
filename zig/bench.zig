const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const fmt = @import("index_fmt.zig");
const index_read = @import("index_read.zig");
const index_build = @import("index_build.zig");
const live_mod = @import("live.zig");
const walk = @import("walk.zig");
const query_mod = @import("query.zig");
const search_mod = @import("search.zig");
const baseline = @import("search_baseline.zig");
const measure = @import("measure.zig");
const engine_mod = @import("engine.zig");
const app_mod = @import("app.zig");
const view_mod = @import("view.zig");
const gpu_rest = @import("gpu_rest.zig");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn getpid() c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: u16) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
extern "c" fn posix_spawn(pid: *c_int, path: [*:0]const u8, actions: ?*const anyopaque, attr: ?*const anyopaque, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn posix_spawn_file_actions_init(a: *?*anyopaque) c_int;
extern "c" fn posix_spawn_file_actions_destroy(a: *?*anyopaque) c_int;
extern "c" fn posix_spawn_file_actions_adddup2(a: *?*anyopaque, fd: c_int, newfd: c_int) c_int;
extern "c" fn posix_spawn_file_actions_addclose(a: *?*anyopaque, fd: c_int) c_int;
extern "c" fn posix_spawn_file_actions_addopen(a: *?*anyopaque, fd: c_int, path: [*:0]const u8, oflag: c_int, mode: c_uint) c_int;
extern "c" fn system(cmd: [*:0]const u8) c_int;

const budgets = [_]measure.Budget{
    .{ .name = "index_dirty_mb", .budget = 2.5, .target = 0.5 },
    .{ .name = "idle_mb", .budget = 45.0, .target = 28.0 },
    .{ .name = "list_10k_mb", .budget = 50.0, .target = 32.0 },
    .{ .name = "scroll_p50_ms", .budget = 4.0, .target = 0.5 },
    .{ .name = "view_switch_p50_ms", .budget = 6.0, .target = 1.0 },
    .{ .name = "search_sub_p50_us", .budget = 50.0, .target = 10.0 },
    .{ .name = "search_fuzzy_p50_us", .budget = 150.0, .target = 35.0 },
    .{ .name = "home_load_ms", .budget = 5.0, .target = 1.0 },
    .{ .name = "leaks", .budget = 0.0, .target = 0.0 },
};

const QueryBenchRow = struct {
    query: []const u8,
    hits: usize,
    tier: u8,
    zigder_p50_us: f64,
    zigder_p95_us: f64,
    founder_p50_us: f64,
    founder_p95_us: f64,
    speedup: f64,
};

fn mb(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / @as(f64, 1 << 20);
}

fn drawFrame(t: *ui.Tester, target: anytype) void {
    if (comptime ui.portable) return;
    t.renderer.syncImages(&t.text.images);
    t.renderer.textures = t.ctx.textures.items;
    t.renderer.gradients = t.ctx.gradients.items;
    _ = t.renderer.drawTimed(target, t.instances.items, t.text.texture(), t.size, t.ctx.theme.background);
}

fn restedFootprintMb(r: anytype) f64 {
    gpu_rest.restRenderer(r);
    measure.releaseHeap();
    var prev = measure.footprint().now;
    var stable: usize = 0;
    for (0..25) |_| {
        nanoui.runFor(0.02);
        measure.releaseHeap();
        const cur = measure.footprint().now;
        const diff = if (cur > prev) cur - prev else prev - cur;
        if (diff <= (256 << 10) and cur < (80 << 20)) {
            stable += 1;
            if (stable >= 2) return mb(cur);
        } else {
            stable = 0;
        }
        prev = cur;
    }
    return mb(measure.footprint().now);
}

fn writeFd(fd: c_int, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = write(fd, bytes[off..].ptr, bytes.len - off);
        if (n <= 0) break;
        off += @intCast(n);
    }
}

fn pOut(gpa: std.mem.Allocator, comptime fmt_s: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(gpa, fmt_s, args) catch return;
    defer gpa.free(s);
    writeFd(1, s);
}

fn ensureParentDir(path: []const u8) void {
    const dir = std.fs.path.dirname(path) orelse return;
    var buf: [2048]u8 = undefined;
    for (dir, 0..) |ch, i| {
        if (i >= buf.len - 1) return;
        if (ch == '/' and i > 0) {
            buf[i] = 0;
            _ = mkdir(@ptrCast(&buf), 0o755);
        }
        buf[i] = ch;
    }
    if (dir.len < buf.len) {
        buf[dir.len] = 0;
        _ = mkdir(@ptrCast(&buf), 0o755);
    }
}

fn populateDirFiles(gpa: std.mem.Allocator, dir: []const u8, count: usize) !void {
    const dir_z = try gpa.dupeSentinel(u8, dir, 0);
    defer gpa.free(dir_z);
    _ = mkdir(dir_z, 0o755);
    var pbuf: [256]u8 = undefined;
    for (0..count) |i| {
        const pz = try std.fmt.bufPrintSentinel(&pbuf, "{s}/item_{d:0>5}.txt", .{ dir, i }, 0);
        const fd = open(pz, 0x0601, @as(c_int, 0o644));
        if (fd >= 0) _ = close(fd);
    }
}

fn removeTree(root: []const u8) void {
    var cmd: [256]u8 = undefined;
    const s = std.fmt.bufPrintSentinel(&cmd, "rm -rf '{s}'", .{root}, 0) catch return;
    _ = system(s);
}

fn captureLeaks(gpa: std.mem.Allocator, pid: c_int) !f64 {
    var pid_buf: [16]u8 = undefined;
    const pid_s = try std.fmt.bufPrintSentinel(&pid_buf, "{d}", .{pid}, 0);
    var fds: [2]c_int = undefined;
    if (pipe(&fds) != 0) return error.Pipe;
    var fa: ?*anyopaque = null;
    _ = posix_spawn_file_actions_init(&fa);
    defer _ = posix_spawn_file_actions_destroy(&fa);
    _ = posix_spawn_file_actions_adddup2(&fa, fds[1], 1);
    _ = posix_spawn_file_actions_adddup2(&fa, fds[1], 2);
    _ = posix_spawn_file_actions_addclose(&fa, fds[0]);
    const path_z: [*:0]const u8 = "/usr/bin/leaks";
    const argv = [_:null]?[*:0]const u8{ path_z, pid_s.ptr };
    const envp = [_:null]?[*:0]const u8{ "LC_ALL=C", "PATH=/usr/bin:/bin:/usr/sbin:/sbin" };
    var child: c_int = 0;
    const rc = posix_spawn(&child, path_z, @ptrCast(&fa), null, &argv, &envp);
    _ = close(fds[1]);
    if (rc != 0) {
        _ = close(fds[0]);
        return error.Spawn;
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var rbuf: [8192]u8 = undefined;
    while (true) {
        const n = read(fds[0], &rbuf, rbuf.len);
        if (n == 0) break;
        if (n < 0) continue;
        try out.appendSlice(gpa, rbuf[0..@intCast(n)]);
    }
    _ = close(fds[0]);
    var status: c_int = 0;
    _ = waitpid(child, &status, 0);
    if (measure.parseLeaks(out.items)) |c| return @floatFromInt(c);
    writeFd(2, out.items);
    return std.math.inf(f64);
}

pub fn main() !void {
    const gpa = std.heap.c_allocator;
    const home = if (getenv("HOME")) |h| std.mem.span(h) else "/";
    const pid = getpid();

    const bench_root = try std.fmt.allocPrint(gpa, "/tmp/zigder-bench-{d}", .{pid});
    defer {
        removeTree(bench_root);
        gpa.free(bench_root);
    }
    const bench_root_z = try gpa.dupeSentinel(u8, bench_root, 0);
    defer gpa.free(bench_root_z);
    _ = mkdir(bench_root_z, 0o755);

    const dir1k = try std.fmt.allocPrint(gpa, "{s}/dir1k", .{bench_root});
    defer gpa.free(dir1k);
    const dir10k = try std.fmt.allocPrint(gpa, "{s}/dir10k", .{bench_root});
    defer gpa.free(dir10k);
    try populateDirFiles(gpa, dir1k, 1000);
    try populateDirFiles(gpa, dir10k, 10000);

    const founder_path = try std.fmt.allocPrint(gpa, "{s}/Library/Application Support/Founder/fsearch/index.bin", .{home});
    defer gpa.free(founder_path);
    const cache_zidx = try std.fmt.allocPrint(gpa, "{s}/Library/Caches/zigder/index.zidx", .{home});
    defer gpa.free(cache_zidx);

    var founder_opt: ?fmt.FounderIndex = fmt.FounderIndex.load(founder_path) catch null;
    defer if (founder_opt) |*f| f.deinit();

    var zidx_path: []const u8 = cache_zidx;
    var convert_ms: f64 = 0;
    var tmp_zidx: ?[]u8 = null;
    defer if (tmp_zidx) |p| gpa.free(p);

    if (founder_opt) |*f| {
        var need_convert = true;
        if (index_read.Index.load(cache_zidx)) |existing_const| {
            var existing = existing_const;
            if (existing.n == f.n) need_convert = false;
            existing.deinit();
        } else |_| {}
        if (need_convert) {
            ensureParentDir(cache_zidx);
            const t0 = measure.nanos();
            try index_build.buildFromFounder(f, cache_zidx);
            convert_ms = @as(f64, @floatFromInt(measure.nanos() - t0)) / 1e6;
        }
    } else {
        const tz = try std.fmt.allocPrint(gpa, "{s}/synth.zidx", .{bench_root});
        tmp_zidx = tz;
        zidx_path = tz;
        var scanned = try walk.scan(gpa, bench_root, &.{}, 4);
        defer scanned.deinit();
        try index_build.buildFromListings(scanned.listings.items, 1, query_mod.nowSecs(), home, tz);
    }

    measure.releaseHeap();
    measure.resetPeak();
    const fp_before_idx = measure.footprint().now;
    const t_load0 = measure.nanos();
    const idx = try index_read.Index.load(zidx_path);
    const live = try live_mod.Live.init(gpa, idx);
    const index_load_ms = @as(f64, @floatFromInt(measure.nanos() - t_load0)) / 1e6;
    const fp_after_idx = measure.footprint().now;
    const index_dirty_mb = @max(0.0, mb(fp_after_idx) - mb(fp_before_idx));

    var engine = engine_mod.Engine.init(gpa);
    defer engine.deinit();
    engine.attachLive(live);

    var state = try app_mod.AppState.init(gpa, &engine, home, dir1k, true);
    defer state.deinit();

    var tester: ui.Tester = undefined;
    try tester.init(gpa, .init(&state, view_mod.view), .{ .width = 1220, .height = 780, .scale = 2 });
    defer tester.deinit();

    tester.settle(1.0);
    {
        const px = try tester.render(std.heap.page_allocator);
        px.deinit(std.heap.page_allocator);
    }
    const active_gpu_mb = mb(measure.footprint().now);
    const idle_mb = restedFootprintMb(&tester.renderer);

    const Target = if (comptime ui.portable) void else nanoui.objc.Object;
    const target: Target = if (comptime ui.portable) {} else tester.renderer.newTarget(tester.size, tester.scale);

    try state.navigateTo(dir10k, false);
    tester.frame();
    drawFrame(&tester, target);

    var scroll_ms: [30]f64 = undefined;
    for (&scroll_ms) |*slot| {
        const ts = measure.nanos();
        tester.scroll(600, 360, -48);
        drawFrame(&tester, target);
        slot.* = @as(f64, @floatFromInt(measure.nanos() - ts)) / 1e6;
    }
    const scroll_stats = measure.Stats.of(&scroll_ms);

    const modes = [_]app_mod.ViewMode{ .list, .column, .icon, .gallery };
    var switch_ms: [20]f64 = undefined;
    for (&switch_ms, 0..) |*slot, i| {
        const ts = measure.nanos();
        state.setViewMode(modes[i % modes.len]);
        tester.frame();
        drawFrame(&tester, target);
        slot.* = @as(f64, @floatFromInt(measure.nanos() - ts)) / 1e6;
    }
    state.setViewMode(.list);
    tester.frame();
    drawFrame(&tester, target);
    if (comptime !ui.portable) nanoui.objc.release(target);
    const switch_stats = measure.Stats.of(&switch_ms);
    const list_10k_mb = restedFootprintMb(&tester.renderer);
    const leaks = try captureLeaks(gpa, pid);

    const bench_queries = [_][]const u8{
        "zigder",
        "nanoui",
        "Cargo.toml",
        "package.json",
        "README.md",
        "^main",
        "config ext:json",
        "kind:dir devv",
        "type:app Safari",
        "fdrfs",
    };

    var qrows: [bench_queries.len]QueryBenchRow = undefined;
    var z_res: search_mod.SearchResults = .{};
    defer z_res.deinit(gpa);
    var f_hits: std.ArrayList(baseline.BaselineHit) = .empty;
    defer f_hits.deinit(gpa);

    var live_ref = &engine.live.?;
    for (bench_queries, 0..) |qstr, qi| {
        var q = try query_mod.Query.parse(gpa, qstr, home);
        defer q.deinit(gpa);
        q.limit = 50;

        for (0..3) |_| try search_mod.search(gpa, live_ref, &q, null, &z_res);
        var z_samples: [25]f64 = undefined;
        for (&z_samples) |*slot| {
            const ts = measure.nanos();
            try search_mod.search(gpa, live_ref, &q, null, &z_res);
            slot.* = @as(f64, @floatFromInt(measure.nanos() - ts)) / 1000.0;
        }
        const z_stats = measure.Stats.of(&z_samples);
        const hits_len = z_res.hits.items.len;
        const tier_used = z_res.tier_used;

        var f_stats: measure.Stats = .{ .min = 0, .p50 = 0, .p95 = 0 };
        if (founder_opt) |*f| {
            for (0..3) |_| _ = try baseline.baselineFounderSearch(gpa, f, &q, &f_hits);
            var f_samples: [15]f64 = undefined;
            for (&f_samples) |*slot| {
                const ts = measure.nanos();
                _ = try baseline.baselineFounderSearch(gpa, f, &q, &f_hits);
                slot.* = @as(f64, @floatFromInt(measure.nanos() - ts)) / 1000.0;
            }
            f_stats = measure.Stats.of(&f_samples);
        }
        const speedup = if (z_stats.p50 > 0 and f_stats.p50 > 0) f_stats.p50 / z_stats.p50 else 0;
        qrows[qi] = .{
            .query = qstr,
            .hits = hits_len,
            .tier = tier_used,
            .zigder_p50_us = z_stats.p50,
            .zigder_p95_us = z_stats.p95,
            .founder_p50_us = f_stats.p50,
            .founder_p95_us = f_stats.p95,
            .speedup = speedup,
        };
    }

    var cache: search_mod.SearchCache = .{};
    defer cache.deinit(gpa);
    const keystrokes = [_][]const u8{ "z", "zi", "zig", "zigd", "zigde", "zigder" };
    var ks_samples: [keystrokes.len]f64 = undefined;
    for (keystrokes, 0..) |ks, ki| {
        var kq = try query_mod.Query.parse(gpa, ks, home);
        defer kq.deinit(gpa);
        kq.limit = 50;
        const ts = measure.nanos();
        try search_mod.search(gpa, live_ref, &kq, &cache, &z_res);
        ks_samples[ki] = @as(f64, @floatFromInt(measure.nanos() - ts)) / 1000.0;
    }
    const keystroke_last_us = ks_samples[ks_samples.len - 1];

    const devv_path = try std.fmt.allocPrint(gpa, "{s}/devv", .{home});
    defer gpa.free(devv_path);
    const t_tot = measure.nanos();
    const devv_tot = live_ref.totals(devv_path);
    const totals_us = @as(f64, @floatFromInt(measure.nanos() - t_tot)) / 1000.0;

    const bench_probe = try std.fmt.allocPrint(gpa, "{s}/.zigder_bench_probe", .{home});
    defer gpa.free(bench_probe);
    if (live_ref.base.lookup(home)) |he| {
        if (live_ref.base.dirOf(he)) |hd| {
            const s = live_ref.base.dirStart()[hd];
            const end = live_ref.base.dirEnd()[hd];
            if (s < end) live_ref.kill(@intCast(s));
        }
    }
    try live_ref.putOverlay(bench_probe, walk.KIND_FILE, 128, 4096, query_mod.nowSecs());
    var home_samples: [5]f64 = undefined;
    for (&home_samples) |*slot| {
        const ts = measure.nanos();
        var hl = try engine.loadFolder(gpa, home, .name, true, true, false);
        slot.* = @as(f64, @floatFromInt(measure.nanos() - ts)) / 1e6;
        hl.deinit(gpa);
    }
    const home_load_stats = measure.Stats.of(&home_samples);
    live_ref.removePath(bench_probe);

    pOut(gpa, "\n=== zigder offscreen benchmark (entries={d}) ===\n", .{live_ref.base.n});
    pOut(gpa, "index_load_ms={d:.2} convert_ms={d:.1} index_dirty_mb={d:.2} active_gpu_mb={d:.2} idle_mb={d:.2} list_10k_mb={d:.2}\n", .{
        index_load_ms, convert_ms, index_dirty_mb, active_gpu_mb, idle_mb, list_10k_mb,
    });
    pOut(gpa, "scroll_p50_ms={d:.3} view_switch_p50_ms={d:.3} keystroke_cached_us={d:.2} totals_us={d:.2} home_load_ms={d:.3} (has_devv={}) leaks={d:.0}\n\n", .{
        scroll_stats.p50, switch_stats.p50, keystroke_last_us, totals_us, home_load_stats.p50, devv_tot != null, leaks,
    });
    pOut(gpa, "{s:<18} | {s:>4} | {s:>4} | {s:>10} | {s:>10} | {s:>10} | {s:>8}\n", .{
        "query", "hits", "tier", "zig_p50_us", "zig_p95_us", "fnd_p50_us", "speedup",
    });
    for (qrows) |row| {
        pOut(gpa, "{s:<18} | {d:>4} | T{d:>3} | {d:>10.2} | {d:>10.2} | {d:>10.1} | {d:>7.1}x\n", .{
            row.query, row.hits, row.tier, row.zigder_p50_us, row.zigder_p95_us, row.founder_p50_us, row.speedup,
        });
    }

    const sub_p50_us = @max(
        qrows[2].zigder_p50_us,
        @max(qrows[3].zigder_p50_us, @max(qrows[4].zigder_p50_us, @max(qrows[5].zigder_p50_us, qrows[6].zigder_p50_us))),
    );
    const metrics = [_]measure.Metric{
        .{ .name = "index_dirty_mb", .value = index_dirty_mb },
        .{ .name = "idle_mb", .value = idle_mb },
        .{ .name = "list_10k_mb", .value = list_10k_mb },
        .{ .name = "scroll_p50_ms", .value = scroll_stats.p50 },
        .{ .name = "view_switch_p50_ms", .value = switch_stats.p50 },
        .{ .name = "search_sub_p50_us", .value = sub_p50_us },
        .{ .name = "search_fuzzy_p50_us", .value = qrows[0].zigder_p50_us },
        .{ .name = "home_load_ms", .value = home_load_stats.p50 },
        .{ .name = "leaks", .value = leaks },
    };

    var all_ok = true;
    writeFd(1, "\n{\"budgets\":[");
    for (metrics, 0..) |m, mi| {
        const v = measure.judge(m, &budgets);
        if (!v.ok()) all_ok = false;
        if (mi > 0) writeFd(1, ",");
        pOut(gpa, "{{\"name\":\"{s}\",\"value\":{d:.3},\"ok\":{}}}", .{ m.name, m.value, v.ok() });
    }
    writeFd(1, "]}\n");

    if (!all_ok) {
        writeFd(2, "budget check failed\n");
        std.process.exit(1);
    }
}
