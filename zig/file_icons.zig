const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_mod = @import("app.zig");
const fs_entry = @import("fs_entry.zig");
const theme = @import("theme.zig");
const walk = @import("walk.zig");

extern "c" fn CGColorSpaceCreateDeviceRGB() ?*anyopaque;
extern "c" fn CGColorSpaceRelease(space: *anyopaque) void;
extern "c" fn CGBitmapContextCreate(data: ?*anyopaque, w: usize, h: usize, bpc: usize, bpr: usize, space: ?*anyopaque, info: u32) ?*anyopaque;
extern "c" fn CGContextDrawImage(ctx: *anyopaque, rect: nanoui.objc.CGRect, image: *anyopaque) void;
extern "c" fn CGContextRelease(ctx: *anyopaque) void;

const gpa = std.heap.smp_allocator;
const small_side: u32 = 32;
const large_side: u32 = 128;
const small_max_pt: f32 = 20;
const live_bytes_max: usize = 24 * 1024 * 1024;
const premultiplied_bgra: u32 = 2 | (2 << 12);

const Pixels = std.AutoHashMapUnmanaged(u64, ?[]u8);
var live: Pixels = .empty;
var retired: Pixels = .empty;
var live_bytes: usize = 0;

pub fn beginFrame() void {
    if (live_bytes < live_bytes_max) return;
    var it = retired.valueIterator();
    while (it.next()) |px| if (px.*) |bytes| gpa.free(bytes);
    retired.deinit(gpa);
    retired = live;
    live = .empty;
    live_bytes = 0;
}

pub fn cacheKey(full: []const u8, container: bool) u64 {
    const name = std.fs.path.basename(full);
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse 0;
    if (container or dot == 0 or dot + 1 == name.len) return std.hash.Wyhash.hash(1, full);
    var hasher = std.hash.Wyhash.init(2);
    for (name[dot + 1 ..]) |ch| hasher.update(&.{std.ascii.toLower(ch)});
    return hasher.final();
}

pub fn entry(c: *ui.Context, listing: *const fs_entry.FolderListing, e: fs_entry.DirEntry, pt: f32, spec: theme.IconSpec, tint: ?ui.Color) void {
    var buf: [2048]u8 = undefined;
    const container = (e.kind & 3) == walk.KIND_LINK or e.isFolderRow() or (e.flags & fs_entry.FLAG_APP) != 0 or e.isPackage();
    if (app_mod.joinBuf(&buf, listing.path, listing.nameOf(e))) |full| {
        if (show(c, full, container, pt)) return;
    }
    symbol(c, pt, spec, tint);
}

pub fn path(c: *ui.Context, full: []const u8, kind: u8, pt: f32, spec: theme.IconSpec, tint: ?ui.Color) void {
    if (show(c, full, (kind & 3) != walk.KIND_FILE, pt)) return;
    symbol(c, pt, spec, tint);
}

fn symbol(c: *ui.Context, pt: f32, spec: theme.IconSpec, tint: ?ui.Color) void {
    const small = pt <= small_max_pt;
    ui.icon(c, spec.name, .{ .size = if (small) pt - 1 else pt, .color = tint orelse spec.color, .frame = if (small) pt + 2 else null });
}

fn show(c: *ui.Context, full: []const u8, container: bool, pt: f32) bool {
    if (comptime ui.portable) return false;
    const side: u32 = if (pt <= small_max_pt) small_side else large_side;
    const key = cacheKey(full, container) ^ side;
    const bgra = pixels(key, full, side) orelse return false;
    return ui.image(c, .{
        .key = c.print("file-icon-{x}", .{key}),
        .source = .{ .pixels = .{ .bgra = bgra, .width = side, .height = side } },
        .box = .{ .w = pt, .h = pt },
        .radius = 0,
    });
}

fn pixels(key: u64, full: []const u8, side: u32) ?[]u8 {
    if (live.get(key)) |found| return found;
    const drawn = rasterize(full, side);
    live.put(gpa, key, drawn) catch {
        if (drawn) |bytes| gpa.free(bytes);
        return null;
    };
    if (drawn) |bytes| live_bytes += bytes.len;
    return drawn;
}

pub fn rasterize(full: []const u8, side: u32) ?[]u8 {
    if (comptime ui.portable) return null;
    const objc = nanoui.objc;
    const pool = objc.Pool.push();
    defer pool.pop();
    const workspace = objc.msg(?objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{}) orelse return null;
    const image = objc.msg(?objc.Object, workspace, "iconForFile:", .{objc.nsString(full)}) orelse return null;
    var rect: objc.CGRect = .{ .size = .{ .width = @floatFromInt(side), .height = @floatFromInt(side) } };
    const cg = objc.msg(?*anyopaque, image, "CGImageForProposedRect:context:hints:", .{ &rect, @as(?objc.Object, null), @as(?objc.Object, null) }) orelse return null;

    const bytes = gpa.alloc(u8, @as(usize, side) * side * 4) catch return null;
    @memset(bytes, 0);
    const space = CGColorSpaceCreateDeviceRGB() orelse {
        gpa.free(bytes);
        return null;
    };
    defer CGColorSpaceRelease(space);
    const ctx = CGBitmapContextCreate(bytes.ptr, side, side, 8, @as(usize, side) * 4, space, premultiplied_bgra) orelse {
        gpa.free(bytes);
        return null;
    };
    defer CGContextRelease(ctx);
    CGContextDrawImage(ctx, .{ .size = .{ .width = @floatFromInt(side), .height = @floatFromInt(side) } }, cg);
    return bytes;
}
