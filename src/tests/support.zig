const std = @import("std");
const walk = @import("../index/walk.zig");
const index_build = @import("../index/build.zig");
const engine_mod = @import("../index/engine.zig");

extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
extern "c" fn system(cmd: [*:0]const u8) c_int;
extern "c" fn lstat(path: [*:0]const u8, buf: *std.c.Stat) c_int;

pub fn sh(comptime fmt_str: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    const cmd = try std.fmt.bufPrintSentinel(&buf, fmt_str, args, 0);
    try std.testing.expectEqual(@as(c_int, 0), system(cmd));
}

pub fn existsAt(comptime fmt_str: []const u8, args: anytype) bool {
    var buf: [512]u8 = undefined;
    const pz = std.fmt.bufPrintSentinel(&buf, fmt_str, args, 0) catch return false;
    var st: std.c.Stat = undefined;
    return lstat(pz, &st) == 0;
}

pub fn sizeAt(comptime fmt_str: []const u8, args: anytype) ?u64 {
    var buf: [512]u8 = undefined;
    const pz = std.fmt.bufPrintSentinel(&buf, fmt_str, args, 0) catch return null;
    var st: std.c.Stat = undefined;
    if (lstat(pz, &st) != 0) return null;
    return @intCast(@max(st.size, 0));
}

pub const TempDir = struct {
    buf: [64:0]u8 = @splat(0),
    len: usize = 0,

    pub fn create(prefix: []const u8) !TempDir {
        var out: TempDir = .{};
        const full = try std.fmt.bufPrint(out.buf[0..out.buf.len], "{s}-XXXXXX", .{prefix});
        _ = mkdtemp(&out.buf) orelse return error.TmpDir;
        out.len = full.len;
        return out;
    }

    pub fn path(self: *const TempDir) [:0]const u8 {
        return self.buf[0..self.len :0];
    }

    pub fn cleanup(self: *const TempDir) void {
        if (self.len > 0) sh("rm -rf '{s}'", .{self.path()}) catch {};
    }
};

pub fn buildFlatIndex(gpa: std.mem.Allocator, root: []const u8, idx_path: []const u8, event_id: u64) !void {
    var scanned = try walk.scan(gpa, root, &.{}, 2);
    defer scanned.deinit();
    try index_build.buildFromListings(scanned.listings.items, event_id, 1700000000, root, idx_path);
}

pub fn buildRootedIndex(gpa: std.mem.Allocator, root: []const u8, idx_path: []const u8, event_id: u64) !void {
    var scanned = try walk.scan(gpa, root, &.{}, 2);
    defer scanned.deinit();
    var l0: walk.Listing = .{ .id = 0 };
    defer l0.deinit(gpa);
    try l0.names.appendSlice(gpa, "tmp");
    try l0.ents.append(gpa, .{ .name_off = 0, .name_len = 3, .kind = walk.KIND_DIR, .size = 0, .alloc = 0, .mtime = 0, .child = 1 });
    const root_nm = std.fs.path.basename(root);
    var l1: walk.Listing = .{ .id = 1 };
    defer l1.deinit(gpa);
    try l1.names.appendSlice(gpa, root_nm);
    try l1.ents.append(gpa, .{ .name_off = 0, .name_len = @intCast(root_nm.len), .kind = walk.KIND_DIR, .size = 0, .alloc = 0, .mtime = 0, .child = 2 });
    for (scanned.listings.items) |*l| {
        l.id += 2;
        for (l.ents.items) |*r| {
            if (r.child != walk.NONE) r.child += 2;
        }
    }
    var full: std.ArrayList(walk.Listing) = .empty;
    defer full.deinit(gpa);
    try full.append(gpa, l0);
    try full.append(gpa, l1);
    try full.appendSlice(gpa, scanned.listings.items);
    try index_build.buildFromListings(full.items, event_id, 1700000000, root, idx_path);
}

pub fn initFixtureEngine(gpa: std.mem.Allocator, root: []const u8, idx_name: []const u8) !engine_mod.Engine {
    var buf: [128]u8 = undefined;
    const idx_path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ root, idx_name });
    try buildFlatIndex(gpa, root, idx_path, 1);
    return engine_mod.Engine.initHeadlessWithIndex(gpa, idx_path);
}
