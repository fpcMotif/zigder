const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;

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
    const clean_dir = if (dir.len > 1) std.mem.trimEnd(u8, dir, "/") else dir;
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
    else if (std.mem.eql(u8, clean_dir, "/"))
        try std.fmt.allocPrint(gpa, "/{s}", .{name})
    else
        try std.fmt.allocPrint(gpa, "{s}/{s}", .{ clean_dir, name });
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

fn copyToExactPath(gpa: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
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

pub fn moveToExactPath(gpa: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    const src_z = try gpa.dupeSentinel(u8, src, 0);
    defer gpa.free(src_z);
    const dst_z = try gpa.dupeSentinel(u8, dst, 0);
    defer gpa.free(dst_z);
    if (renamex_np(src_z, dst_z, RENAME_EXCL) == 0) return;
    if (pathExists(dst)) return error.DestinationExists;
    if (rename(src_z, dst_z) == 0) return;
    try copyToExactPath(gpa, src, dst);
    try deleteImmediately(gpa, src);
}

pub fn renameItem(gpa: std.mem.Allocator, path: []const u8, new_name: []const u8) ![]u8 {
    if (new_name.len == 0 or std.mem.indexOfScalar(u8, new_name, '/') != null) return error.InvalidName;
    const parent = std.fs.path.dirname(path) orelse "/";
    const dst = if (std.mem.eql(u8, parent, "/"))
        try std.fmt.allocPrint(gpa, "/{s}", .{new_name})
    else
        try std.fmt.allocPrint(gpa, "{s}/{s}", .{ parent, new_name });
    errdefer gpa.free(dst);
    if (std.mem.eql(u8, path, dst)) return dst;
    if (pathExists(dst)) return error.NameTaken;
    const src_z = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(src_z);
    const dst_z = try gpa.dupeSentinel(u8, dst, 0);
    defer gpa.free(dst_z);
    if (rename(src_z, dst_z) != 0) return error.RenameFailed;
    return dst;
}

pub fn createFolder(gpa: std.mem.Allocator, dir: []const u8, base_name: []const u8) ![]u8 {
    const dst = try uniqueDest(gpa, dir, base_name, false);
    errdefer gpa.free(dst);
    const dst_z = try gpa.dupeSentinel(u8, dst, 0);
    defer gpa.free(dst_z);
    if (mkdir(dst_z, 0o755) != 0) return error.MkdirFailed;
    return dst;
}

pub fn createFile(gpa: std.mem.Allocator, dir: []const u8, base_name: []const u8) ![]u8 {
    const dst = try uniqueDest(gpa, dir, base_name, false);
    errdefer gpa.free(dst);
    const dst_z = try gpa.dupeSentinel(u8, dst, 0);
    defer gpa.free(dst_z);
    const fd = open(dst_z, O_WRONLY | O_CREAT | O_EXCL, @as(c_int, 0o644));
    if (fd < 0) return error.CreateFileFailed;
    _ = close(fd);
    return dst;
}

pub fn deleteImmediately(gpa: std.mem.Allocator, path: []const u8) !void {
    const pz = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(pz);
    var st: std.c.Stat = undefined;
    if (lstat(pz, &st) != 0) return;
    if ((st.mode & 0o170000) == 0o040000) {
        try deleteDirTree(gpa, path);
    } else {
        if (unlink(pz) != 0) return error.UnlinkFailed;
    }
}

fn deleteDirTree(gpa: std.mem.Allocator, path: []const u8) !void {
    const walk = @import("walk.zig");
    var listing: walk.Listing = .{ .id = 0 };
    defer listing.deinit(gpa);
    if (walk.listOne(gpa, path, &listing)) {
        for (listing.ents.items) |r| {
            const nm = listing.entName(r);
            const cp = if (std.mem.eql(u8, path, "/"))
                try std.fmt.allocPrint(gpa, "/{s}", .{nm})
            else
                try std.fmt.allocPrint(gpa, "{s}/{s}", .{ path, nm });
            defer gpa.free(cp);
            if ((r.kind & 3) == walk.KIND_DIR) {
                try deleteDirTree(gpa, cp);
            } else {
                const cz = try gpa.dupeSentinel(u8, cp, 0);
                defer gpa.free(cz);
                _ = unlink(cz);
            }
        }
    }
    const pz = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(pz);
    if (rmdir(pz) != 0) return error.RmdirFailed;
}

fn removeCreated(gpa: std.mem.Allocator, path: []const u8, is_dir: bool) !void {
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

pub fn readFilesFromPasteboard(gpa: std.mem.Allocator) !?[][]u8 {
    return nanoui.clipboard.readFiles(gpa);
}

pub fn freePaths(gpa: std.mem.Allocator, paths: [][]u8) void {
    for (paths) |p| gpa.free(p);
    gpa.free(paths);
}

pub const UndoKind = enum {
    move,
    copy,
    rename,
    create,
    trash,
};

pub const UndoEntry = struct {
    kind: UndoKind,
    from: []u8,
    to: []u8,

    fn deinit(e: UndoEntry, gpa: std.mem.Allocator) void {
        gpa.free(e.from);
        gpa.free(e.to);
    }
};

pub const max_undo = 64;

pub const UndoStack = struct {
    undo_list: std.ArrayList(UndoEntry) = .empty,
    redo_list: std.ArrayList(UndoEntry) = .empty,

    pub fn deinit(u: *UndoStack, gpa: std.mem.Allocator) void {
        for (u.undo_list.items) |e| e.deinit(gpa);
        u.undo_list.deinit(gpa);
        for (u.redo_list.items) |e| e.deinit(gpa);
        u.redo_list.deinit(gpa);
    }

    pub fn record(u: *UndoStack, gpa: std.mem.Allocator, kind: UndoKind, from: []const u8, to: []const u8) !void {
        for (u.redo_list.items) |e| e.deinit(gpa);
        u.redo_list.clearRetainingCapacity();
        if (u.undo_list.items.len >= max_undo) {
            u.undo_list.items[0].deinit(gpa);
            _ = u.undo_list.orderedRemove(0);
        }
        try u.undo_list.append(gpa, .{
            .kind = kind,
            .from = try gpa.dupe(u8, from),
            .to = try gpa.dupe(u8, to),
        });
    }

    pub fn undo(u: *UndoStack, gpa: std.mem.Allocator) !bool {
        const entry = u.undo_list.pop() orelse return false;
        var keep_entry = entry;
        errdefer keep_entry.deinit(gpa);
        switch (entry.kind) {
            .move, .rename => {
                try moveToExactPath(gpa, entry.to, entry.from);
            },
            .copy => {
                try deleteImmediately(gpa, entry.to);
            },
            .create => {
                try removeCreated(gpa, entry.to, std.mem.eql(u8, entry.from, "dir"));
            },
            .trash => {
                if (entry.to.len == 0) return error.CannotPutBack;
                try moveToExactPath(gpa, entry.to, entry.from);
            },
        }
        try u.redo_list.append(gpa, keep_entry);
        return true;
    }

    pub fn redo(u: *UndoStack, gpa: std.mem.Allocator) !bool {
        const entry = u.redo_list.pop() orelse return false;
        var keep_entry = entry;
        errdefer keep_entry.deinit(gpa);
        switch (entry.kind) {
            .move, .rename => {
                try moveToExactPath(gpa, entry.from, entry.to);
            },
            .copy => {
                try copyToExactPath(gpa, entry.from, entry.to);
            },
            .create => {
                const pz = try gpa.dupeSentinel(u8, entry.to, 0);
                defer gpa.free(pz);
                if (std.mem.eql(u8, entry.from, "dir")) {
                    if (mkdir(pz, 0o755) != 0) return error.MkdirFailed;
                } else {
                    const fd = open(pz, O_WRONLY | O_CREAT | O_EXCL, @as(c_int, 0o644));
                    if (fd < 0) return error.CreateFileFailed;
                    _ = close(fd);
                }
            },
            .trash => {
                const trashed = try trashItem(gpa, entry.from);
                gpa.free(keep_entry.to);
                keep_entry.to = trashed;
            },
        }
        try u.undo_list.append(gpa, keep_entry);
        return true;
    }
};
