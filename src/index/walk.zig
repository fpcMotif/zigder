const std = @import("std");
const tcc = @import("tcc.zig");
const index_read = @import("read.zig");
const Scratch = @import("scratch.zig").Scratch;

extern "c" fn setiopolicy_np(iotype: c_int, scope: c_int, policy: c_int) c_int;
extern "c" fn getattrlistbulk(dirfd: c_int, alist: *AttrList, buf: *anyopaque, size: usize, options: u64) c_int;
extern "c" fn getattrlistat(fd: c_int, path: [*:0]const u8, alist: *AttrList, buf: *anyopaque, size: usize, options: u64) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn openat(fd: c_int, path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn getrlimit(resource: c_int, rlp: *RLimit) c_int;
extern "c" fn setrlimit(resource: c_int, rlp: *const RLimit) c_int;

const RLIMIT_NOFILE = 8;
const RLimit = extern struct {
    rlim_cur: u64,
    rlim_max: u64,
};

const AttrList = extern struct {
    bitmapcount: u16 = 5,
    reserved: u16 = 0,
    commonattr: u32 = 0,
    volattr: u32 = 0,
    dirattr: u32 = 0,
    fileattr: u32 = 0,
    forkattr: u32 = 0,
};

const ATTR_CMN_NAME: u32 = 0x00000001;
const ATTR_CMN_OBJTYPE: u32 = 0x00000008;
const ATTR_CMN_MODTIME: u32 = 0x00000400;
const ATTR_CMN_FLAGS: u32 = 0x00040000;
const ATTR_CMN_ERROR: u32 = 0x20000000;
const ATTR_CMN_RETURNED_ATTRS: u32 = 0x80000000;

const ATTR_DIR_ENTRYCOUNT: u32 = 0x00000002;
const ATTR_DIR_MOUNTSTATUS: u32 = 0x00000004;
const DIR_MNTSTATUS_MNTPOINT: u32 = 0x00000001;
const DIR_MNTSTATUS_TRIGGER: u32 = 0x00000002;

const ATTR_FILE_LINKCOUNT: u32 = 0x00000001;
const ATTR_FILE_ALLOCSIZE: u32 = 0x00000004;
const ATTR_FILE_DATALENGTH: u32 = 0x00000200;

const FSOPT_NOFOLLOW: u64 = 0x00000001;
const UF_HIDDEN: u32 = 0x00008000;
const SF_FIRMLINK: u32 = 0x00800000;

const O_RDONLY: c_int = 0;
const O_NOFOLLOW: c_int = 0x0100;
const O_DIRECTORY: c_int = 0x100000;
const O_CLOEXEC: c_int = 0x1000000;
const OPEN_DIR: c_int = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC;

pub const NONE: u32 = std.math.maxInt(u32);
pub const KIND_FILE: u8 = 0;
pub const KIND_DIR: u8 = 1;
pub const KIND_LINK: u8 = 2;
pub const KIND_OTHER: u8 = 3;

pub fn kindFromMode(mode: std.c.mode_t) u8 {
    return switch (mode & 0o170000) {
        0o100000 => KIND_FILE,
        0o040000 => KIND_DIR,
        0o120000 => KIND_LINK,
        else => KIND_OTHER,
    };
}

pub const FLAG_HIDDEN: u8 = 1 << 2;
pub const FLAG_MOUNT: u8 = 1 << 3;
pub const FLAG_HARDLINK: u8 = 1 << 4;
const MAYBE_EMPTY: u8 = 1 << 7;

pub const RawEnt = struct {
    name_off: u32,
    name_len: u16,
    kind: u8,
    size: u64,
    alloc: u64,
    mtime: u32,
    child: u32,
};

pub const Listing = struct {
    id: u32,
    names: std.ArrayList(u8) = .empty,
    ents: std.ArrayList(RawEnt) = .empty,

    pub fn deinit(l: *Listing, gpa: std.mem.Allocator) void {
        l.names.deinit(gpa);
        l.ents.deinit(gpa);
    }

    pub fn entName(l: *const Listing, r: RawEnt) []const u8 {
        return l.names.items[r.name_off..][0..r.name_len];
    }
};

pub const ScanResult = struct {
    scratches: []Scratch,
    listings: std.ArrayList(Listing),
    gpa: std.mem.Allocator,

    pub fn entryCount(s: *const ScanResult) usize {
        var n: usize = 0;
        for (s.listings.items) |l| n += l.ents.items.len;
        return n;
    }

    pub fn deinit(s: *ScanResult) void {
        for (s.scratches) |*a| a.deinit();
        s.gpa.free(s.scratches);
    }
};

pub fn noMaterialize() void {
    _ = setiopolicy_np(3, 1, 1);
}

fn raiseFdLimit() void {
    var r: RLimit = .{ .rlim_cur = 0, .rlim_max = 0 };
    if (getrlimit(RLIMIT_NOFILE, &r) == 0) {
        r.rlim_cur = @min(r.rlim_max, 65536);
        _ = setrlimit(RLIMIT_NOFILE, &r);
    }
}

fn rd32(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

fn rdi32(b: []const u8, at: usize) i32 {
    return std.mem.readInt(i32, b[at..][0..4], .little);
}

fn rd64(b: []const u8, at: usize) u64 {
    return std.mem.readInt(u64, b[at..][0..8], .little);
}

fn rdi64(b: []const u8, at: usize) i64 {
    return std.mem.readInt(i64, b[at..][0..8], .little);
}

pub fn listOne(gpa: std.mem.Allocator, path: []const u8, out_listing: *Listing) bool {
    var path_buf: [2048]u8 = undefined;
    const cpath = std.fmt.bufPrintSentinel(&path_buf, "{s}", .{path}, 0) catch return false;
    const fd = open(cpath, OPEN_DIR);
    if (fd < 0) return false;
    defer _ = close(fd);
    var scratch: [128 * 1024]u8 align(8) = undefined;
    listFd(gpa, fd, &scratch, out_listing);
    for (out_listing.ents.items) |*e| e.kind &= ~MAYBE_EMPTY;
    return true;
}

fn listFd(gpa: std.mem.Allocator, fd: c_int, buf: []align(8) u8, l: *Listing) void {
    var al: AttrList = .{
        .commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_ERROR | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_FLAGS,
        .dirattr = ATTR_DIR_ENTRYCOUNT | ATTR_DIR_MOUNTSTATUS,
        .fileattr = ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE | ATTR_FILE_DATALENGTH,
    };
    while (true) {
        const n = getattrlistbulk(fd, &al, buf.ptr, buf.len, 0);
        if (n <= 0) break;
        const count: usize = @intCast(n);
        var p: usize = 0;
        var name_bytes: usize = 0;
        for (0..count) |_| {
            const rec_len = rd32(buf, p);
            const common = rd32(buf, p + 4);
            if (common & ATTR_CMN_NAME != 0) {
                const f: usize = if (common & ATTR_CMN_ERROR != 0) 28 else 24;
                const nlen = rd32(buf, p + f + 4);
                name_bytes += nlen -| 1;
            }
            p += rec_len;
        }
        l.ents.ensureUnusedCapacity(gpa, count) catch return;
        l.names.ensureUnusedCapacity(gpa, name_bytes) catch return;
        p = 0;
        for (0..count) |_| {
            const rec_len = rd32(buf, p);
            parseEntry(buf[p .. p + rec_len], l);
            p += rec_len;
        }
    }
}

fn parseEntry(b: []const u8, l: *Listing) void {
    if (b.len < 24) return;
    const common = rd32(b, 4);
    const dirattr = rd32(b, 12);
    const fileattr = rd32(b, 16);
    var f: usize = 24;
    if (common & ATTR_CMN_ERROR != 0) f += 4;
    if (common & ATTR_CMN_NAME == 0) return;
    const off: isize = rdi32(b, f);
    const nlen = rd32(b, f + 4);
    const start_signed = @as(isize, @intCast(f)) + off;
    if (start_signed < 0) return;
    const start: usize = @intCast(start_signed);
    const name_len = nlen -| 1;
    if (start + name_len > b.len) return;
    const name = b[start .. start + name_len];
    f += 8;

    var kind: u8 = KIND_OTHER;
    if (common & ATTR_CMN_OBJTYPE != 0) {
        kind = switch (rd32(b, f)) {
            1 => KIND_FILE,
            2 => KIND_DIR,
            5 => KIND_LINK,
            else => KIND_OTHER,
        };
        f += 4;
    }
    var mtime: u32 = 0;
    if (common & ATTR_CMN_MODTIME != 0) {
        const sec = rdi64(b, f);
        mtime = if (sec <= 0) 0 else @intCast(@min(sec, std.math.maxInt(u32)));
        f += 16;
    }
    var flags: u32 = 0;
    if (common & ATTR_CMN_FLAGS != 0) {
        flags = rd32(b, f);
        if (flags & UF_HIDDEN != 0) kind |= FLAG_HIDDEN;
        f += 4;
    }
    if (dirattr & ATTR_DIR_ENTRYCOUNT != 0) {
        if (rd32(b, f) == 0 and (flags & SF_FIRMLINK) == 0) kind |= MAYBE_EMPTY;
        f += 4;
    }
    if (dirattr & ATTR_DIR_MOUNTSTATUS != 0) {
        if (rd32(b, f) & (DIR_MNTSTATUS_MNTPOINT | DIR_MNTSTATUS_TRIGGER) != 0) kind |= FLAG_MOUNT;
        f += 4;
    }
    var size: u64 = 0;
    var alloc: u64 = 0;
    if (fileattr & ATTR_FILE_LINKCOUNT != 0) {
        if (rd32(b, f) > 1) kind |= FLAG_HARDLINK;
        f += 4;
    }
    if (fileattr & ATTR_FILE_ALLOCSIZE != 0) {
        alloc = rd64(b, f);
        f += 8;
    }
    if (fileattr & ATTR_FILE_DATALENGTH != 0) {
        size = rd64(b, f);
    }
    if (name.len == 0 or name.len > std.math.maxInt(u16)) return;
    const noff: u32 = @intCast(l.names.items.len);
    l.names.appendSliceAssumeCapacity(name);
    l.ents.appendAssumeCapacity(.{
        .name_off = noff,
        .name_len = @intCast(name.len),
        .kind = kind,
        .size = size,
        .alloc = alloc,
        .mtime = mtime,
        .child = NONE,
    });
}

fn entryCount(dir: c_int, name_z: [*:0]const u8) ?u32 {
    var al: AttrList = .{ .dirattr = ATTR_DIR_ENTRYCOUNT };
    var b: [2]u32 = .{ 0, 0 };
    if (getattrlistat(dir, name_z, &al, &b, @sizeOf([2]u32), FSOPT_NOFOLLOW) == 0) {
        return b[1];
    }
    return null;
}

const DirFd = struct {
    fd: c_int,
    refs: std.atomic.Value(u32),

    fn create(fd: c_int) !*DirFd {
        const d = try std.heap.c_allocator.create(DirFd);
        d.* = .{ .fd = fd, .refs = .init(1) };
        return d;
    }

    fn retain(d: *DirFd, count: u32) void {
        if (count > 0) _ = d.refs.fetchAdd(count, .monotonic);
    }

    fn release(d: *DirFd) void {
        if (d.refs.fetchSub(1, .acq_rel) == 1) {
            if (d.fd >= 0) _ = close(d.fd);
            std.heap.c_allocator.destroy(d);
        }
    }
};

const WorkItem = struct {
    parent: ?*DirFd,
    name_z: ?[:0]u8,
    id: u32,
    path: ?[]u8,
};

fn freeWorkItem(item: WorkItem) void {
    if (item.parent) |p| p.release();
    if (item.name_z) |nz| std.heap.c_allocator.free(nz);
    if (item.path) |p| std.heap.c_allocator.free(p);
}

const ScanCtx = struct {
    skip_paths: []const []const u8,
    track_paths: bool,
    cancel: ?*const std.atomic.Value(bool) = null,
    next_id: std.atomic.Value(u32) = .init(1),
    active: usize = 0,
    done: bool = false,
    canceled: bool = false,
    mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    cond: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER,
    stack: std.ArrayList(WorkItem) = .empty,
    scratches: []Scratch,
    buckets: []std.ArrayList(Listing),
    gpa: std.mem.Allocator,

    inline fn isCanceled(ctx: *const ScanCtx) bool {
        return if (ctx.cancel) |c| c.load(.acquire) else false;
    }

    fn pushWork(ctx: *ScanCtx, items: []const WorkItem) void {
        if (items.len == 0) return;
        var drop_items = false;
        _ = std.c.pthread_mutex_lock(&ctx.mutex);
        if (ctx.done or ctx.isCanceled()) {
            if (ctx.isCanceled()) ctx.canceled = true;
            ctx.done = true;
            drop_items = true;
        } else {
            ctx.stack.appendSlice(std.heap.c_allocator, items) catch {
                drop_items = true;
            };
        }
        _ = std.c.pthread_cond_broadcast(&ctx.cond);
        _ = std.c.pthread_mutex_unlock(&ctx.mutex);
        if (drop_items) {
            for (items) |it| freeWorkItem(it);
        }
    }

    fn popWork(ctx: *ScanCtx, worker_finished_one: bool) ?WorkItem {
        _ = std.c.pthread_mutex_lock(&ctx.mutex);
        defer _ = std.c.pthread_mutex_unlock(&ctx.mutex);
        if (worker_finished_one) ctx.active -= 1;
        while (true) {
            if (ctx.isCanceled()) {
                ctx.canceled = true;
                while (ctx.stack.pop()) |rem| freeWorkItem(rem);
                ctx.done = true;
                _ = std.c.pthread_cond_broadcast(&ctx.cond);
                return null;
            }
            if (ctx.stack.items.len > 0) {
                ctx.active += 1;
                return ctx.stack.pop();
            }
            if (ctx.active == 0) {
                ctx.done = true;
                _ = std.c.pthread_cond_broadcast(&ctx.cond);
                return null;
            }
            if (ctx.done) return null;
            _ = std.c.pthread_cond_wait(&ctx.cond, &ctx.mutex);
        }
    }
};

pub fn scan(gpa: std.mem.Allocator, root: []const u8, skip_paths: []const []const u8, thread_count: usize) !ScanResult {
    return scanCancel(gpa, root, skip_paths, thread_count, null);
}

pub fn scanCancel(gpa: std.mem.Allocator, root: []const u8, skip_paths: []const []const u8, thread_count: usize, cancel: ?*const std.atomic.Value(bool)) !ScanResult {
    if (cancel) |c| if (c.load(.acquire)) return error.Canceled;
    raiseFdLimit();
    const workers = @max(@min(thread_count, 16), 1);
    const scratches = try gpa.alloc(Scratch, workers);
    for (scratches) |*a| a.* = Scratch.init();
    errdefer {
        for (scratches) |*a| a.deinit();
        gpa.free(scratches);
    }
    const buckets = try gpa.alloc(std.ArrayList(Listing), workers);
    for (buckets) |*b| b.* = .empty;
    defer gpa.free(buckets);

    var ctx: ScanCtx = .{
        .skip_paths = skip_paths,
        .track_paths = skip_paths.len > 0,
        .cancel = cancel,
        .scratches = scratches,
        .buckets = buckets,
        .gpa = gpa,
    };
    defer ctx.stack.deinit(std.heap.c_allocator);

    var root_fd: c_int = -1;
    if (!tcc.isBlocked(root, skip_paths)) {
        var rbuf: [2048]u8 = undefined;
        if (std.fmt.bufPrintSentinel(&rbuf, "{s}", .{root}, 0)) |rz| {
            root_fd = open(rz, OPEN_DIR);
        } else |_| {}
    }
    const root_path: ?[]u8 = if (ctx.track_paths) try std.heap.c_allocator.dupe(u8, root) else null;
    {
        var wbuf: [128 * 1024]u8 align(8) = undefined;
        finishDir(&ctx, 0, &wbuf, root_fd, root_path, 0);
    }

    var threads: [16]?std.Thread = @splat(null);
    for (1..workers) |w| {
        threads[w] = std.Thread.spawn(.{}, workerMain, .{ &ctx, w }) catch null;
    }
    workerMain(&ctx, 0);
    for (1..workers) |w| {
        if (threads[w]) |th| th.join();
    }
    while (ctx.stack.pop()) |rem| freeWorkItem(rem);
    if (ctx.canceled or ctx.isCanceled()) return error.Canceled;

    var total: usize = 0;
    for (buckets) |b| total += b.items.len;
    var out: std.ArrayList(Listing) = .empty;
    try out.ensureTotalCapacity(scratches[0].allocator(), total);
    for (buckets) |*b| out.appendSliceAssumeCapacity(b.items);
    return .{ .scratches = scratches, .listings = out, .gpa = gpa };
}

fn workerMain(ctx: *ScanCtx, wid: usize) void {
    noMaterialize();
    var buf: [128 * 1024]u8 align(8) = undefined;
    var had_work = false;
    while (ctx.popWork(had_work)) |item| {
        had_work = true;
        var fd: c_int = -1;
        if (item.parent) |p| {
            if (item.name_z) |nz| {
                fd = openat(p.fd, nz.ptr, OPEN_DIR);
            }
            p.release();
        }
        if (item.name_z) |nz| std.heap.c_allocator.free(nz);
        finishDir(ctx, wid, &buf, fd, item.path, item.id);
    }
}

fn finishDir(ctx: *ScanCtx, wid: usize, buf: []align(8) u8, fd: c_int, path: ?[]u8, id: u32) void {
    defer if (path) |p| std.heap.c_allocator.free(p);
    const agpa = ctx.scratches[wid].allocator();
    var l: Listing = .{ .id = id };
    if (fd < 0) {
        ctx.buckets[wid].append(agpa,l) catch {};
        return;
    }
    if (ctx.isCanceled()) {
        _ = close(fd);
        return;
    }
    listFd(agpa, fd, buf, &l);
    if (ctx.isCanceled()) {
        _ = close(fd);
        return;
    }
    const df = DirFd.create(fd) catch {
        _ = close(fd);
        ctx.buckets[wid].append(agpa,l) catch {};
        return;
    };

    var kids: std.ArrayList(WorkItem) = .empty;
    defer kids.deinit(std.heap.c_allocator);
    for (l.ents.items) |*e| {
        const maybe_empty = (e.kind & MAYBE_EMPTY) != 0;
        e.kind &= ~MAYBE_EMPTY;
        if ((e.kind & 3) == KIND_DIR and (e.kind & FLAG_MOUNT) == 0) {
            const name = l.entName(e.*);
            var child_path: ?[]u8 = null;
            if (path) |p| {
                const cp = index_read.joinAlloc(std.heap.c_allocator, p, name);
                if (cp) |cstr| {
                    if (tcc.isBlocked(cstr, ctx.skip_paths)) {
                        std.heap.c_allocator.free(cstr);
                        continue;
                    }
                    child_path = cstr;
                } else |_| continue;
            }
            e.child = ctx.next_id.fetchAdd(1, .monotonic);
            const nz = std.heap.c_allocator.dupeSentinel(u8, name, 0) catch {
                if (child_path) |cp| std.heap.c_allocator.free(cp);
                continue;
            };
            if (maybe_empty and child_path == null and entryCount(fd, nz.ptr) == 0) {
                std.heap.c_allocator.free(nz);
                ctx.buckets[wid].append(agpa,.{ .id = e.child }) catch {};
            } else {
                kids.append(std.heap.c_allocator, .{
                    .parent = df,
                    .name_z = nz,
                    .id = e.child,
                    .path = child_path,
                }) catch {
                    std.heap.c_allocator.free(nz);
                    if (child_path) |cp| std.heap.c_allocator.free(cp);
                };
            }
        }
    }
    ctx.buckets[wid].append(agpa,l) catch {};
    df.retain(@intCast(kids.items.len));
    ctx.pushWork(kids.items);
    df.release();
}
