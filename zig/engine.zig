const std = @import("std");
const nanoui = @import("nanoui");
const fmt = @import("index_fmt.zig");
const index_read = @import("index_read.zig");
const index_build = @import("index_build.zig");
const live_mod = @import("live.zig");
const live_sync = @import("live_sync.zig");
const walk = @import("walk.zig");
const query_mod = @import("query.zig");
const search_mod = @import("search.zig");
const fs_entry = @import("fs_entry.zig");
const quicklook = @import("quicklook.zig");
const fsevents = @import("fsevents.zig");
const measure = @import("measure.zig");

const Config = struct {
    zidx_path: []u8,
    founder_path: ?[]u8,
    scan_root: ?[]u8,
    home: []u8,
    enable_fsevents: bool,

    fn deinit(c: *Config, gpa: std.mem.Allocator) void {
        gpa.free(c.zidx_path);
        if (c.founder_path) |p| gpa.free(p);
        if (c.scan_root) |p| gpa.free(p);
        gpa.free(c.home);
    }
};

pub const QueuedEvent = struct {
    path: []u8,
    flags: u32,
    id: u64,
    stream: u32,
};

fn freeQueuedEvents(gpa: std.mem.Allocator, items: []const QueuedEvent) void {
    for (items) |q| gpa.free(q.path);
}

pub const Engine = struct {
    gpa: std.mem.Allocator,
    mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    wake_mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    ev_mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    ev_cond: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER,
    ev_queue: std.ArrayList(QueuedEvent) = .empty,
    ev_thread: ?std.Thread = null,
    watch_dir: []u8 = &.{},
    live: ?live_mod.Live = null,
    stream: ?*fsevents.Stream = null,
    worker: ?std.Thread = null,
    cfg: ?Config = null,
    stopping: std.atomic.Value(bool) = .init(false),
    ready: std.atomic.Value(bool) = .init(false),
    indexing: std.atomic.Value(bool) = .init(false),
    rescan_wanted: std.atomic.Value(bool) = .init(false),
    search_active: std.atomic.Value(bool) = .init(false),
    generation: std.atomic.Value(u64) = .init(1),
    ui_wakes: std.atomic.Value(u64) = .init(0),
    entry_count: std.atomic.Value(u64) = .init(0),
    waker_win: ?*nanoui.Window = null,

    pub fn init(gpa: std.mem.Allocator) Engine {
        return .{ .gpa = gpa };
    }

    pub fn initHeadlessWithIndex(gpa: std.mem.Allocator, zidx_path: []const u8) !Engine {
        var eng = init(gpa);
        var idx = try index_read.Index.load(zidx_path);
        const lv = live_mod.Live.init(gpa, idx) catch |err| {
            idx.deinit();
            return err;
        };
        eng.live = lv;
        eng.entry_count.store(idx.n, .release);
        eng.ready.store(true, .release);
        return eng;
    }

    pub fn attachLive(self: *Engine, lv: live_mod.Live) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);
        if (self.live) |*old| old.deinit();
        self.entry_count.store(lv.base.n, .release);
        self.live = lv;
        self.ready.store(true, .release);
        _ = self.generation.fetchAdd(1, .release);
    }

    pub fn loadExistingSync(self: *Engine, zidx_path: []const u8) bool {
        const idx = index_read.Index.load(zidx_path) catch return false;
        const lv = live_mod.Live.init(self.gpa, idx) catch {
            var tmp = idx;
            tmp.deinit();
            return false;
        };
        self.attachLive(lv);
        return true;
    }

    pub fn configure(
        self: *Engine,
        zidx_path: []const u8,
        founder_path: ?[]const u8,
        scan_root: ?[]const u8,
        home: []const u8,
        enable_fsevents: bool,
    ) !void {
        if (self.indexing.load(.acquire)) return error.WorkerRunning;
        const gpa = self.gpa;
        const zp = try gpa.dupe(u8, zidx_path);
        errdefer gpa.free(zp);
        const fp: ?[]u8 = if (founder_path) |p| try gpa.dupe(u8, p) else null;
        errdefer if (fp) |p| gpa.free(p);
        const sr: ?[]u8 = if (scan_root) |p| try gpa.dupe(u8, p) else null;
        errdefer if (sr) |p| gpa.free(p);
        const hm = try gpa.dupe(u8, home);
        if (self.cfg) |*old| old.deinit(gpa);
        self.cfg = .{
            .zidx_path = zp,
            .founder_path = fp,
            .scan_root = sr,
            .home = hm,
            .enable_fsevents = enable_fsevents,
        };
    }

    pub fn startAsync(
        self: *Engine,
        zidx_path: []const u8,
        founder_path: ?[]const u8,
        scan_root: ?[]const u8,
        home: []const u8,
        enable_fsevents: bool,
    ) !void {
        try self.configure(zidx_path, founder_path, scan_root, home, enable_fsevents);
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);
        try self.spawnWorkerLocked(false);
    }

    fn spawnWorkerLocked(self: *Engine, force_scan: bool) !void {
        if (self.worker) |th| {
            th.join();
            self.worker = null;
        }
        self.indexing.store(true, .release);
        self.worker = std.Thread.spawn(.{}, workerMain, .{ self, force_scan }) catch |err| {
            self.indexing.store(false, .release);
            return err;
        };
    }

    fn requestRescan(self: *Engine) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);
        if (self.stopping.load(.acquire)) return;
        const cfg = self.cfg orelse return;
        if (cfg.scan_root == null) return;
        if (self.indexing.load(.acquire)) {
            self.rescan_wanted.store(true, .release);
            return;
        }
        self.spawnWorkerLocked(true) catch {};
    }

    pub fn waitIdle(self: *Engine) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        const th = self.worker;
        self.worker = null;
        _ = std.c.pthread_mutex_unlock(&self.mutex);
        if (th) |t| t.join();
    }

    pub fn stop(self: *Engine) void {
        self.stopping.store(true, .release);
        self.setWaker(null);
        self.swapStream(null);
        _ = std.c.pthread_mutex_lock(&self.ev_mutex);
        _ = std.c.pthread_cond_broadcast(&self.ev_cond);
        const ev_th = self.ev_thread;
        self.ev_thread = null;
        _ = std.c.pthread_mutex_unlock(&self.ev_mutex);
        if (ev_th) |th| th.join();
        self.waitIdle();
    }

    pub fn deinit(self: *Engine) void {
        self.stop();
        _ = std.c.pthread_mutex_lock(&self.ev_mutex);
        freeQueuedEvents(self.gpa, self.ev_queue.items);
        self.ev_queue.deinit(self.gpa);
        if (self.watch_dir.len > 0) self.gpa.free(self.watch_dir);
        self.watch_dir = &.{};
        _ = std.c.pthread_mutex_unlock(&self.ev_mutex);
        _ = std.c.pthread_mutex_lock(&self.mutex);
        if (self.live) |*lv| lv.deinit();
        self.live = null;
        _ = std.c.pthread_mutex_unlock(&self.mutex);
        if (self.cfg) |*c| c.deinit(self.gpa);
        self.cfg = null;
    }

    pub fn loadFolder(
        self: *Engine,
        gpa: std.mem.Allocator,
        path: []const u8,
        col: fs_entry.SortCol,
        asc: bool,
        folders_first: bool,
        show_hidden: bool,
    ) !fs_entry.FolderListing {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);
        const lv_ptr: ?*const live_mod.Live = if (self.live) |*lv| lv else null;
        return fs_entry.loadFolder(gpa, path, lv_ptr, col, asc, folders_first, show_hidden);
    }

    pub fn loadInspector(self: *Engine, path: []const u8) quicklook.InspectorPreview {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);
        const lv_ptr: ?*const live_mod.Live = if (self.live) |*lv| lv else null;
        return quicklook.InspectorPreview.load(path, lv_ptr);
    }

    pub fn runSearch(
        self: *Engine,
        gpa: std.mem.Allocator,
        home: []const u8,
        raw_query: []const u8,
        scope_override: ?[]const u8,
        limit: usize,
        out: *search_mod.SearchResults,
    ) !void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);
        const lv: *const live_mod.Live = if (self.live) |*ptr| ptr else {
            out.clear();
            return;
        };
        var q = try query_mod.Query.parse(gpa, raw_query, home);
        defer q.deinit(gpa);
        if (q.scope == null) {
            if (scope_override) |sc| q.scope = try gpa.dupe(u8, sc);
        }
        q.limit = limit;
        try search_mod.search(gpa, lv, &q, out);
    }

    pub fn recordChange(self: *Engine, dir_path: []const u8) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        if (self.live) |*lv| {
            _ = lv.applyDir(dir_path, false, &.{}) catch {};
        }
        _ = std.c.pthread_mutex_unlock(&self.mutex);
        _ = self.generation.fetchAdd(1, .release);
    }

    pub fn totals(self: *Engine, dir_path: []const u8) ?fmt.Totals {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);
        if (self.live) |*lv| return lv.totals(dir_path);
        return null;
    }

    pub fn setUiWatch(self: *Engine, dir_path: []const u8, search_active: bool) void {
        self.search_active.store(search_active, .release);
        const clean = index_read.trimTrailingSlash(dir_path);
        _ = std.c.pthread_mutex_lock(&self.ev_mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.ev_mutex);
        if (std.mem.eql(u8, self.watch_dir, clean)) return;
        const next = self.gpa.dupe(u8, clean) catch return;
        if (self.watch_dir.len > 0) self.gpa.free(self.watch_dir);
        self.watch_dir = next;
    }

    pub fn applyEvents(self: *Engine, batch: []const fsevents.Event) void {
        self.processEventsBatch(batch, &.{});
    }

    pub fn processEventsBatch(
        self: *Engine,
        batch: []const fsevents.Event,
        skip_paths: []const []const u8,
    ) void {
        if (self.stopping.load(.acquire) or batch.len == 0) return;

        var dirs: std.StringHashMapUnmanaged(bool) = .empty;
        defer dirs.deinit(self.gpa);
        var rescan = false;
        var max_id: u64 = 0;

        for (batch) |ev| {
            if (ev.id > max_id) max_id = ev.id;
            if ((ev.flags & fsevents.HISTORY_DONE) != 0) continue;
            if ((ev.flags & (fsevents.USER_DROPPED | fsevents.KERNEL_DROPPED)) != 0) {
                rescan = true;
                continue;
            }
            const cp = live_sync.canonicalEventPath(ev.path) orelse continue;
            const rec = (ev.flags & fsevents.MUST_SCAN_SUBDIRS) != 0;
            if (rec and std.mem.eql(u8, cp, "/")) {
                rescan = true;
                continue;
            }
            const gop = dirs.getOrPut(self.gpa, cp) catch continue;
            if (gop.found_existing) {
                gop.value_ptr.* = gop.value_ptr.* or rec;
            } else {
                gop.value_ptr.* = rec;
            }
        }

        var targets: std.StringHashMapUnmanaged(bool) = .empty;
        defer {
            var tit = targets.keyIterator();
            while (tit.next()) |k| self.gpa.free(k.*);
            targets.deinit(self.gpa);
        }
        {
            _ = std.c.pthread_mutex_lock(&self.mutex);
            defer _ = std.c.pthread_mutex_unlock(&self.mutex);
            if (self.live) |*lv| {
                if (max_id > lv.event_id) lv.event_id = max_id;
                var dit = dirs.iterator();
                while (dit.next()) |kv| {
                    const resolved = live_sync.resolveSyncDir(lv, kv.key_ptr.*, skip_paths) orelse continue;
                    const rec = kv.value_ptr.* and std.mem.eql(u8, resolved, kv.key_ptr.*);
                    const key_copy = self.gpa.dupe(u8, resolved) catch continue;
                    const gop = targets.getOrPut(self.gpa, key_copy) catch {
                        self.gpa.free(key_copy);
                        continue;
                    };
                    if (gop.found_existing) {
                        self.gpa.free(key_copy);
                        gop.value_ptr.* = gop.value_ptr.* or rec;
                    } else {
                        gop.value_ptr.* = rec;
                    }
                }
            }
        }

        var fetched: std.ArrayList(live_sync.FetchedTarget) = .empty;
        defer {
            for (fetched.items) |*ft| ft.deinit(self.gpa);
            fetched.deinit(self.gpa);
        }
        var tit = targets.iterator();
        while (tit.next()) |kv| {
            if (self.stopping.load(.acquire)) return;
            const ft = live_sync.fetchTarget(self.gpa, kv.key_ptr.*, kv.value_ptr.*, skip_paths) catch continue;
            fetched.append(self.gpa, ft) catch {
                var dead_ft = ft;
                dead_ft.deinit(self.gpa);
            };
        }

        var pending_subdirs: std.ArrayList([]u8) = .empty;
        defer {
            for (pending_subdirs.items) |p| self.gpa.free(p);
            pending_subdirs.deinit(self.gpa);
        }
        var mutated_dirs: std.ArrayList([]const u8) = .empty;
        defer mutated_dirs.deinit(self.gpa);

        {
            _ = std.c.pthread_mutex_lock(&self.mutex);
            defer _ = std.c.pthread_mutex_unlock(&self.mutex);
            if (self.live) |*lv| {
                for (fetched.items) |*ft| {
                    const outcome = live_sync.applyFetched(lv, ft, skip_paths, &pending_subdirs) catch continue;
                    if (outcome.need_rebuild) rescan = true;
                    if (outcome.mutated) mutated_dirs.append(self.gpa, ft.path) catch {};
                }
            }
        }

        if (pending_subdirs.items.len > 0 and !self.stopping.load(.acquire)) {
            if (live_sync.fetchSubtrees(self.gpa, pending_subdirs.items, skip_paths)) |subs_const| {
                var subs = subs_const;
                defer {
                    for (subs.items) |*st| st.deinit(self.gpa);
                    subs.deinit(self.gpa);
                }
                _ = std.c.pthread_mutex_lock(&self.mutex);
                if (self.live) |*lv| {
                    live_sync.applySubtrees(lv, subs.items) catch {};
                }
                _ = std.c.pthread_mutex_unlock(&self.mutex);
            } else |_| {}
        }

        if (rescan) self.requestRescan();
        if (mutated_dirs.items.len == 0) return;

        const search_now = self.search_active.load(.acquire);
        var wbuf: [2048]u8 = undefined;
        var wlen: usize = 0;
        {
            _ = std.c.pthread_mutex_lock(&self.ev_mutex);
            defer _ = std.c.pthread_mutex_unlock(&self.ev_mutex);
            wlen = @min(self.watch_dir.len, wbuf.len);
            if (wlen > 0) @memcpy(wbuf[0..wlen], self.watch_dir[0..wlen]);
        }
        const watch_slice = wbuf[0..wlen];
        var need_wake = search_now;
        if (!need_wake) {
            for (mutated_dirs.items) |md| {
                if (shouldWakeForDir(watch_slice, false, md)) {
                    need_wake = true;
                    break;
                }
            }
        }
        if (need_wake) self.wakeUi();
    }

    pub fn setWaker(self: *Engine, win: ?*nanoui.Window) void {
        _ = std.c.pthread_mutex_lock(&self.wake_mutex);
        self.waker_win = win;
        _ = std.c.pthread_mutex_unlock(&self.wake_mutex);
    }

    fn wakeUi(self: *Engine) void {
        _ = self.generation.fetchAdd(1, .release);
        _ = self.ui_wakes.fetchAdd(1, .release);
        _ = std.c.pthread_mutex_lock(&self.wake_mutex);
        if (self.waker_win) |w| w.redrawFromAnyThread();
        _ = std.c.pthread_mutex_unlock(&self.wake_mutex);
    }

    fn swapStream(self: *Engine, next: ?*fsevents.Stream) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        const old = self.stream;
        const keep = next != null and !self.stopping.load(.acquire);
        self.stream = if (keep) next else null;
        _ = std.c.pthread_mutex_unlock(&self.mutex);
        if (old) |s| s.destroy();
        if (!keep) {
            if (next) |s| s.destroy();
        }
    }

    fn ensureEvThread(self: *Engine, home: []const u8) void {
        _ = std.c.pthread_mutex_lock(&self.ev_mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.ev_mutex);
        if (self.stopping.load(.acquire) or self.ev_thread != null) return;
        const home_copy = self.gpa.dupe(u8, home) catch return;
        self.ev_thread = std.Thread.spawn(.{}, evLoopMain, .{ self, home_copy }) catch {
            self.gpa.free(home_copy);
            return;
        };
    }

    fn buildAndAttach(self: *Engine, force_scan: bool) void {
        const cfg = self.cfg orelse return;
        var loaded_idx: ?index_read.Index = null;
        if (!force_scan) {
            loaded_idx = index_read.Index.load(cfg.zidx_path) catch null;
            if (loaded_idx == null) {
                if (cfg.founder_path) |fp| {
                    if (fmt.FounderIndex.load(fp)) |f_const| {
                        var f = f_const;
                        defer f.deinit();
                        index_build.buildFromFounder(&f, cfg.zidx_path) catch {};
                        measure.releaseHeap();
                        loaded_idx = index_read.Index.load(cfg.zidx_path) catch null;
                    } else |_| {}
                }
            }
        }
        if (loaded_idx == null) {
            const root = cfg.scan_root orelse return;
            if (self.stopping.load(.acquire)) return;
            const skip_paths = walk.gatedPaths(self.gpa, cfg.home) catch &.{};
            defer walk.freePaths(self.gpa, skip_paths);
            const ev_now = fsevents.currentId();
            const sync_now = query_mod.nowSecs();
            var scan_res = walk.scan(self.gpa, root, skip_paths, 4) catch return;
            index_build.buildFromListings(scan_res.listings.items, ev_now, sync_now, cfg.home, cfg.zidx_path) catch {};
            scan_res.deinit();
            measure.releaseHeap();
            loaded_idx = index_read.Index.load(cfg.zidx_path) catch null;
        }

        var idx = loaded_idx orelse return;
        if (self.stopping.load(.acquire)) {
            idx.deinit();
            return;
        }
        const lv = live_mod.Live.init(self.gpa, idx) catch {
            idx.deinit();
            return;
        };
        const since = idx.event_id;
        self.attachLive(lv);
        self.swapStream(null);
        if (cfg.enable_fsevents and !self.stopping.load(.acquire)) {
            self.ensureEvThread(cfg.home);
            if (fsevents.watch(self.gpa, since, 0.5, 1, onFsEvents, self)) |st| {
                self.swapStream(st);
            } else |_| {}
        }
        self.wakeUi();
    }
};

pub fn shouldWakeForDir(watch_dir: []const u8, search_active: bool, mut_dir: []const u8) bool {
    if (search_active) return true;
    if (watch_dir.len == 0) return false;
    if (std.mem.eql(u8, mut_dir, watch_dir)) return true;
    if (std.mem.eql(u8, mut_dir, "/")) return false;
    const mut_parent = std.fs.path.dirname(mut_dir) orelse "/";
    if (std.mem.eql(u8, mut_parent, watch_dir)) return true;
    if (live_sync.hasPathPrefix(watch_dir, mut_dir)) return true;
    return false;
}

fn onFsEvents(ctx: ?*anyopaque, batch: []fsevents.Event) void {
    const self: *Engine = @ptrCast(@alignCast(ctx orelse return));
    if (self.stopping.load(.acquire) or batch.len == 0) return;
    _ = std.c.pthread_mutex_lock(&self.ev_mutex);
    defer _ = std.c.pthread_mutex_unlock(&self.ev_mutex);
    if (self.stopping.load(.acquire)) return;
    for (batch) |ev| {
        const dup = self.gpa.dupe(u8, ev.path) catch continue;
        self.ev_queue.append(self.gpa, .{
            .path = dup,
            .flags = ev.flags,
            .id = ev.id,
            .stream = ev.stream,
        }) catch {
            self.gpa.free(dup);
            continue;
        };
    }
    _ = std.c.pthread_cond_signal(&self.ev_cond);
}

fn evLoopMain(self: *Engine, home_copy: []u8) void {
    walk.noMaterialize();
    defer self.gpa.free(home_copy);
    const skip_paths = walk.gatedPaths(self.gpa, home_copy) catch &.{};
    defer walk.freePaths(self.gpa, skip_paths);

    while (true) {
        var batch: std.ArrayList(QueuedEvent) = .empty;
        _ = std.c.pthread_mutex_lock(&self.ev_mutex);
        while (self.ev_queue.items.len == 0 and !self.stopping.load(.acquire)) {
            _ = std.c.pthread_cond_wait(&self.ev_cond, &self.ev_mutex);
        }
        if (self.stopping.load(.acquire)) {
            _ = std.c.pthread_mutex_unlock(&self.ev_mutex);
            batch.deinit(self.gpa);
            return;
        }
        batch = self.ev_queue;
        self.ev_queue = .empty;
        _ = std.c.pthread_mutex_unlock(&self.ev_mutex);

        const raw_evs = self.gpa.alloc(fsevents.Event, batch.items.len) catch {
            freeQueuedEvents(self.gpa, batch.items);
            batch.deinit(self.gpa);
            continue;
        };
        for (batch.items, 0..) |q, i| {
            raw_evs[i] = .{ .path = q.path, .flags = q.flags, .id = q.id, .stream = q.stream };
        }
        self.processEventsBatch(raw_evs, skip_paths);
        const n = batch.items.len;
        self.gpa.free(raw_evs);
        freeQueuedEvents(self.gpa, batch.items);
        batch.deinit(self.gpa);
        if (n >= 16) measure.releaseHeap();
    }
}

fn workerMain(self: *Engine, force_first: bool) void {
    walk.noMaterialize();
    var force = force_first;
    while (true) {
        if (!self.stopping.load(.acquire)) self.buildAndAttach(force);
        _ = std.c.pthread_mutex_lock(&self.mutex);
        const again = self.rescan_wanted.swap(false, .acq_rel) and !self.stopping.load(.acquire);
        if (!again) self.indexing.store(false, .release);
        _ = std.c.pthread_mutex_unlock(&self.mutex);
        if (!again) break;
        force = true;
    }
}
