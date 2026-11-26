const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const index_read = @import("../index/read.zig");
const walk = @import("../index/walk.zig");

extern "c" fn clonefile(src: [*:0]const u8, dst: [*:0]const u8, flags: u32) c_int;
extern "c" fn copyfile(from: [*:0]const u8, to: [*:0]const u8, state: ?*anyopaque, flags: u32) c_int;
extern "c" fn rename(old: [*:0]const u8, new: [*:0]const u8) c_int;
extern "c" fn renamex_np(old: [*:0]const u8, new: [*:0]const u8, flags: c_uint) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn rmdir(path: [*:0]const u8) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: u16) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn lstat(path: [*:0]const u8, buf: *std.c.Stat) c_int;

const COPYFILE_ALL: u32 = 0x0F;
const COPYFILE_RECURSIVE: u32 = 1 << 15;
const COPYFILE_NOFOLLOW: u32 = (1 << 18) | (1 << 19);
const RENAME_EXCL: c_uint = 0x4;
const O_WRONLY: c_int = 0x0001;
const O_CREAT: c_int = 0x0200;
const O_EXCL: c_int = 0x0800;

fn pathExists(path: []const u8) bool {
    var buf: [2048]u8 = undefined;
    const pz = std.fmt.bufPrintSentinel(&buf, "{s}", .{path}, 0) catch return false;
    var st: std.c.Stat = undefined;
    return lstat(pz, &st) == 0;
}

fn uniqueDest(gpa: std.mem.Allocator, dir: []const u8, name: []const u8, suffix_copy: bool) ![]u8 {
    const clean_dir = index_read.trimTrailingSlash(dir);
    var stem = name;
    var ext: []const u8 = "";
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
        if (dot > 0) {
            stem = name[0..dot];
            ext = name[dot..];
        }
    }
    const base_cand = if (suffix_copy)
        try std.fmt.allocPrint(gpa, "{s}/{s} copy{s}", .{ clean_dir, stem, ext })
    else
        try index_read.joinAlloc(gpa, clean_dir, name);
    if (!pathExists(base_cand)) return base_cand;
    gpa.free(base_cand);

    var n: usize = 2;
    while (n < 10_000) : (n += 1) {
        const cand = if (suffix_copy)
            try std.fmt.allocPrint(gpa, "{s}/{s} copy {d}{s}", .{ clean_dir, stem, n, ext })
        else if (std.mem.eql(u8, clean_dir, "/"))
            try std.fmt.allocPrint(gpa, "/{s} {d}", .{ name, n })
        else
            try std.fmt.allocPrint(gpa, "{s}/{s} {d}", .{ clean_dir, name, n });
        if (!pathExists(cand)) return cand;
        gpa.free(cand);
    }
    return error.NameExhausted;
}

pub fn copyItem(gpa: std.mem.Allocator, src: []const u8, dst_dir: []const u8) ![]u8 {
    const name = std.fs.path.basename(src);
    const dst = try uniqueDest(gpa, dst_dir, name, false);
    errdefer gpa.free(dst);
    try copyToExactPath(gpa, src, dst);
    return dst;
}

pub fn copyToExactPath(gpa: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    const src_z = try gpa.dupeSentinel(u8, src, 0);
    defer gpa.free(src_z);
    const dst_z = try gpa.dupeSentinel(u8, dst, 0);
    defer gpa.free(dst_z);
    if (clonefile(src_z, dst_z, 0) == 0) return;
    if (pathExists(dst)) return error.DestinationExists;
    if (copyfile(src_z, dst_z, null, COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW) != 0) {
        return error.CopyFailed;
    }
}

pub fn duplicateItem(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    const parent = std.fs.path.dirname(src) orelse "/";
    const name = std.fs.path.basename(src);
    const dst = try uniqueDest(gpa, parent, name, true);
    errdefer gpa.free(dst);
    try copyToExactPath(gpa, src, dst);
    return dst;
}

pub fn moveItem(gpa: std.mem.Allocator, src: []const u8, dst_dir: []const u8) ![]u8 {
    const name = std.fs.path.basename(src);
    const dst = try uniqueDest(gpa, dst_dir, name, false);
    errdefer gpa.free(dst);
    try moveToExactPath(gpa, src, dst);
    return dst;
}

fn hasExactChild(gpa: std.mem.Allocator, parent: []const u8, name: []const u8) bool {
    var listing: walk.Listing = .{ .id = 0 };
    defer listing.deinit(gpa);
    if (!walk.listOne(gpa, parent, &listing)) return true;
    for (listing.ents.items) |r| {
        if (std.mem.eql(u8, listing.entName(r), name)) return true;
    }
    return false;
}

fn isSameDirEntryRename(gpa: std.mem.Allocator, src: []const u8, dst: []const u8, src_z: [*:0]const u8, dst_z: [*:0]const u8) bool {
    const src_clean = index_read.trimTrailingSlash(src);
    const dst_clean = index_read.trimTrailingSlash(dst);
    const src_parent = std.fs.path.dirname(src_clean) orelse "/";
    const dst_parent = std.fs.path.dirname(dst_clean) orelse "/";
    if (!std.mem.eql(u8, src_parent, dst_parent)) return false;
    var src_st: std.c.Stat = undefined;
    var dst_st: std.c.Stat = undefined;
    if (lstat(src_z, &src_st) != 0 or lstat(dst_z, &dst_st) != 0) return false;
    if (src_st.dev != dst_st.dev or src_st.ino != dst_st.ino) return false;
    return !hasExactChild(gpa, dst_parent, std.fs.path.basename(dst_clean));
}

pub fn isValidEntryName(name: []const u8) bool {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return std.mem.indexOfAny(u8, name, "/\x00") == null;
}

pub fn moveToExactPath(gpa: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    const src_clean = index_read.trimTrailingSlash(src);
    const dst_clean = index_read.trimTrailingSlash(dst);
    if (std.mem.eql(u8, src_clean, dst_clean)) return;
    if (std.mem.indexOfScalar(u8, src_clean, 0) != null or std.mem.indexOfScalar(u8, dst_clean, 0) != null) {
        return error.InvalidDestination;
    }
    if (index_read.hasPathPrefix(dst_clean, src_clean)) return error.InvalidDestination;
    const src_z = try gpa.dupeSentinel(u8, src_clean, 0);
    defer gpa.free(src_z);
    const dst_z = try gpa.dupeSentinel(u8, dst_clean, 0);
    defer gpa.free(dst_z);
    const rc = renamex_np(src_z, dst_z, RENAME_EXCL);
    if (rc == 0) return;
    switch (std.c.errno(rc)) {
        .EXIST => {
            if (isSameDirEntryRename(gpa, src_clean, dst_clean, src_z, dst_z)) {
                if (rename(src_z, dst_z) != 0) return error.RenameFailed;
                return;
            }
            return error.DestinationExists;
        },
        .XDEV => {
            if (pathExists(dst_clean)) return error.DestinationExists;
            try copyToExactPath(gpa, src_clean, dst_clean);
            try deleteImmediately(gpa, src_clean);
        },
        .OPNOTSUPP => {
            if (pathExists(dst_clean) and !isSameDirEntryRename(gpa, src_clean, dst_clean, src_z, dst_z)) {
                return error.DestinationExists;
            }
            const rrc = rename(src_z, dst_z);
            if (rrc == 0) return;
            if (std.c.errno(rrc) == .XDEV) {
                try copyToExactPath(gpa, src_clean, dst_clean);
                try deleteImmediately(gpa, src_clean);
                return;
            }
            return error.RenameFailed;
        },
        else => return error.RenameFailed,
    }
}

pub fn renameItem(gpa: std.mem.Allocator, path: []const u8, new_name: []const u8) ![]u8 {
    if (!isValidEntryName(new_name) or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidName;
    const parent = std.fs.path.dirname(path) orelse "/";
    const dst = try index_read.joinAlloc(gpa, parent, new_name);
    errdefer gpa.free(dst);
    if (std.mem.eql(u8, path, dst)) return dst;
    const src_z = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(src_z);
    const dst_z = try gpa.dupeSentinel(u8, dst, 0);
    defer gpa.free(dst_z);
    const rc = renamex_np(src_z, dst_z, RENAME_EXCL);
    if (rc == 0) return dst;
    switch (std.c.errno(rc)) {
        .EXIST => {
            if (isSameDirEntryRename(gpa, path, dst, src_z, dst_z)) {
                if (rename(src_z, dst_z) != 0) return error.RenameFailed;
                return dst;
            }
            return error.NameTaken;
        },
        .OPNOTSUPP => {
            if (pathExists(dst) and !isSameDirEntryRename(gpa, path, dst, src_z, dst_z)) return error.NameTaken;
            if (rename(src_z, dst_z) != 0) return error.RenameFailed;
            return dst;
        },
        else => return error.RenameFailed,
    }
}

pub fn createExactDir(gpa: std.mem.Allocator, path: []const u8) !void {
    const pz = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(pz);
    if (mkdir(pz, 0o755) != 0) return error.MkdirFailed;
}

pub fn createExactFile(gpa: std.mem.Allocator, path: []const u8) !void {
    const pz = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(pz);
    const fd = open(pz, O_WRONLY | O_CREAT | O_EXCL, @as(c_int, 0o644));
    if (fd < 0) return error.CreateFileFailed;
    _ = close(fd);
}

pub fn createFolder(gpa: std.mem.Allocator, dir: []const u8, base_name: []const u8) ![]u8 {
    if (!isValidEntryName(base_name)) return error.InvalidName;
    const dst = try uniqueDest(gpa, dir, base_name, false);
    errdefer gpa.free(dst);
    try createExactDir(gpa, dst);
    return dst;
}

pub fn createFile(gpa: std.mem.Allocator, dir: []const u8, base_name: []const u8) ![]u8 {
    if (!isValidEntryName(base_name)) return error.InvalidName;
    const dst = try uniqueDest(gpa, dir, base_name, false);
    errdefer gpa.free(dst);
    try createExactFile(gpa, dst);
    return dst;
}

pub const DevT = @FieldType(std.c.Stat, "dev");

pub const DeleteHooks = struct {
    list_dir: *const fn (std.mem.Allocator, []const u8, *walk.Listing) bool = walk.listOne,
    stat_dev: *const fn ([*:0]const u8) ?DevT = statDev,
};

fn statDev(pz: [*:0]const u8) ?DevT {
    var st: std.c.Stat = undefined;
    if (lstat(pz, &st) != 0) return null;
    return st.dev;
}

pub fn deleteImmediately(gpa: std.mem.Allocator, path: []const u8) !void {
    return deleteImmediatelyWith(gpa, path, .{});
}

pub fn deleteImmediatelyWith(gpa: std.mem.Allocator, raw_path: []const u8, hooks: DeleteHooks) !void {
    const path = index_read.trimTrailingSlash(raw_path);
    if (std.mem.eql(u8, path, "/")) return error.MountPoint;
    const pz = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(pz);
    var st: std.c.Stat = undefined;
    if (lstat(pz, &st) != 0) return;
    if ((st.mode & 0o170000) == 0o040000) {
        const dev = hooks.stat_dev(pz) orelse return error.MountPoint;
        const parent = std.fs.path.dirname(path) orelse "/";
        const par_z = try gpa.dupeSentinel(u8, parent, 0);
        defer gpa.free(par_z);
        const par_dev = hooks.stat_dev(par_z) orelse return error.MountPoint;
        if (dev != par_dev) return error.MountPoint;
        try deleteDirTreeWith(gpa, path, dev, hooks);
    } else {
        if (unlink(pz) != 0) return error.UnlinkFailed;
    }
}

fn deleteDirTreeWith(gpa: std.mem.Allocator, path: []const u8, root_dev: DevT, hooks: DeleteHooks) !void {
    const pz = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(pz);
    const cur_dev = hooks.stat_dev(pz) orelse return error.MountPoint;
    if (cur_dev != root_dev) return error.MountPoint;
    var listing: walk.Listing = .{ .id = 0 };
    defer listing.deinit(gpa);
    if (hooks.list_dir(gpa, path, &listing)) {
        for (listing.ents.items) |r| {
            if ((r.kind & walk.FLAG_MOUNT) != 0) return error.MountPoint;
        }
        for (listing.ents.items) |r| {
            const nm = listing.entName(r);
            const cp = try index_read.joinAlloc(gpa, path, nm);
            defer gpa.free(cp);
            if ((r.kind & 3) == walk.KIND_DIR) {
                try deleteDirTreeWith(gpa, cp, root_dev, hooks);
            } else {
                const cz = try gpa.dupeSentinel(u8, cp, 0);
                defer gpa.free(cz);
                _ = unlink(cz);
            }
        }
    }
    if (rmdir(pz) != 0) return error.RmdirFailed;
}

pub fn removeCreated(gpa: std.mem.Allocator, path: []const u8, is_dir: bool) !void {
    const pz = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(pz);
    var st: std.c.Stat = undefined;
    if (lstat(pz, &st) != 0) return;
    if (is_dir) {
        if (rmdir(pz) != 0) return error.FolderNotEmpty;
    } else {
        if (st.size != 0) return error.FileNotEmpty;
        if (unlink(pz) != 0) return error.UnlinkFailed;
    }
}

pub fn trashItem(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const u = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(path)});
    const fm = objc.msg(objc.Object, objc.class("NSFileManager"), "defaultManager", .{});
    var res_url: ?objc.Object = null;
    const ok = objc.msg(
        objc.BOOL,
        fm,
        "trashItemAtURL:resultingItemURL:error:",
        .{ u, &res_url, @as(?*anyopaque, null) },
    );
    if (!ok) return error.TrashFailed;
    if (res_url) |ru| {
        if (objc.msg(?objc.Object, ru, "path", .{})) |ns_path| {
            return try gpa.dupe(u8, objc.fromNSString(ns_path));
        }
    }
    return try gpa.dupe(u8, "");
}

pub fn copyFilesToPasteboard(paths: []const []const u8) void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const pb = objc.msg(objc.Object, objc.class("NSPasteboard"), "generalPasteboard", .{});
    _ = objc.msg(objc.NSInteger, pb, "clearContents", .{});
    const arr = objc.msg(objc.Object, objc.class("NSMutableArray"), "array", .{});
    for (paths) |p| {
        const u = objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(p)});
        objc.msg(void, arr, "addObject:", .{u});
    }
    _ = objc.msg(objc.BOOL, pb, "writeObjects:", .{arr});
}
