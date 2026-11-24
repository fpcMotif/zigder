const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;

extern "c" fn getfsstat64(buf: ?[*]StatFs64, bufsize: c_int, mode: c_int) c_int;
extern "c" fn getxattr(path: [*:0]const u8, name: [*:0]const u8, value: ?*anyopaque, size: usize, pos: u32, opt: c_int) isize;
extern "c" fn setxattr(path: [*:0]const u8, name: [*:0]const u8, value: *const anyopaque, size: usize, pos: u32, opt: c_int) c_int;
extern "c" fn removexattr(path: [*:0]const u8, name: [*:0]const u8, opt: c_int) c_int;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;

const MNT_NOWAIT: c_int = 2;
const MNT_DONTBROWSE: u32 = 0x00100000;
const XATTR_NOFOLLOW: c_int = 0x0001;
const TAG_XATTR: [*:0]const u8 = "com.apple.metadata:_kMDItemUserTags";

pub const StatFs64 = extern struct {
    f_bsize: u32,
    f_iosize: i32,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_fsid: [2]i32,
    f_owner: u32,
    f_type: u32,
    f_flags: u32,
    f_fssubtype: u32,
    f_fstypename: [16]u8,
    f_mntonname: [1024]u8,
    f_mntfromname: [1024]u8,
    f_flags_ext: u32,
    f_reserved: [7]u32,
};

pub const TagSpec = struct {
    name: []const u8,
    bit: u3,
    rgb: u32,
};

pub const finder_tags = [_]TagSpec{
    .{ .name = "Red", .bit = 0, .rgb = 0xFF3B30 },
    .{ .name = "Orange", .bit = 1, .rgb = 0xFF9500 },
    .{ .name = "Yellow", .bit = 2, .rgb = 0xFFCC00 },
    .{ .name = "Green", .bit = 3, .rgb = 0x28CD41 },
    .{ .name = "Blue", .bit = 4, .rgb = 0x007AFF },
    .{ .name = "Purple", .bit = 5, .rgb = 0xAF52DE },
    .{ .name = "Gray", .bit = 6, .rgb = 0x8E8E93 },
};

pub const SidebarKind = enum {
    favorite,
    location,
    tag,
};

pub const SidebarItem = struct {
    kind: SidebarKind,
    label: []u8,
    path: []u8,
    icon: []const u8,
    total_bytes: u64 = 0,
    free_bytes: u64 = 0,
    tag_bit: u3 = 0,
    tag_rgb: u32 = 0,
};

pub fn freeSidebar(gpa: std.mem.Allocator, items: []SidebarItem) void {
    for (items) |it| {
        gpa.free(it.label);
        gpa.free(it.path);
    }
    gpa.free(items);
}

fn pathExists(p: []const u8) bool {
    var buf: [2048]u8 = undefined;
    const pz = std.fmt.bufPrintSentinel(&buf, "{s}", .{p}, 0) catch return false;
    return access(pz, 0) == 0;
}

pub fn discoverSidebar(gpa: std.mem.Allocator, home: []const u8) ![]SidebarItem {
    var out: std.ArrayList(SidebarItem) = .empty;
    errdefer {
        for (out.items) |it| {
            gpa.free(it.label);
            gpa.free(it.path);
        }
        out.deinit(gpa);
    }

    const clean_home = std.mem.trimEnd(u8, home, "/");
    const favs = [_]struct { label: []const u8, sub: []const u8, icon: []const u8, abs: bool }{
        .{ .label = "Home", .sub = "", .icon = "house.fill", .abs = false },
        .{ .label = "Desktop", .sub = "/Desktop", .icon = "menubar.dock.rectangle", .abs = false },
        .{ .label = "Documents", .sub = "/Documents", .icon = "doc.fill", .abs = false },
        .{ .label = "Downloads", .sub = "/Downloads", .icon = "arrow.down.circle.fill", .abs = false },
        .{ .label = "Applications", .sub = "/Applications", .icon = "square.grid.2x2.fill", .abs = true },
        .{ .label = "Trash", .sub = "/.Trash", .icon = "trash.fill", .abs = false },
    };

    for (favs) |f| {
        const p = if (f.abs)
            try gpa.dupe(u8, f.sub)
        else
            try std.fmt.allocPrint(gpa, "{s}{s}", .{ clean_home, f.sub });
        if (!pathExists(p)) {
            gpa.free(p);
            continue;
        }
        try out.append(gpa, .{
            .kind = .favorite,
            .label = try gpa.dupe(u8, f.label),
            .path = p,
            .icon = f.icon,
        });
    }

    const icloud = try std.fmt.allocPrint(gpa, "{s}/Library/Mobile Documents/com~apple~CloudDocs", .{clean_home});
    if (pathExists(icloud)) {
        try out.append(gpa, .{
            .kind = .favorite,
            .label = try gpa.dupe(u8, "iCloud Drive"),
            .path = icloud,
            .icon = "icloud.fill",
        });
    } else {
        gpa.free(icloud);
    }

    const count = getfsstat64(null, 0, MNT_NOWAIT);
    if (count > 0) {
        const n: usize = @intCast(count);
        const buf = try gpa.alloc(StatFs64, n);
        defer gpa.free(buf);
        const got = getfsstat64(buf.ptr, @intCast(n * @sizeOf(StatFs64)), MNT_NOWAIT);
        if (got > 0) {
            for (buf[0..@intCast(got)]) |st| {
                const mnt = std.mem.sliceTo(&st.f_mntonname, 0);
                const is_root = std.mem.eql(u8, mnt, "/");
                if (!is_root and (st.f_flags & MNT_DONTBROWSE) != 0) continue;
                const is_vol = std.mem.startsWith(u8, mnt, "/Volumes/");
                if (!is_root and !is_vol) continue;
                const label = if (is_root) "Macintosh HD" else std.fs.path.basename(mnt);
                const total = st.f_blocks * st.f_bsize;
                const free_b = st.f_bavail * st.f_bsize;
                try out.append(gpa, .{
                    .kind = .location,
                    .label = try gpa.dupe(u8, label),
                    .path = try gpa.dupe(u8, mnt),
                    .icon = if (is_root) "internaldrive.fill" else "externaldrive.fill",
                    .total_bytes = total,
                    .free_bytes = free_b,
                });
            }
        }
    }

    for (finder_tags) |t| {
        try out.append(gpa, .{
            .kind = .tag,
            .label = try gpa.dupe(u8, t.name),
            .path = try std.fmt.allocPrint(gpa, "tag:{s}", .{t.name}),
            .icon = "circle.fill",
            .tag_bit = t.bit,
            .tag_rgb = t.rgb,
        });
    }

    return try out.toOwnedSlice(gpa);
}

pub fn readTagMask(path: []const u8) u8 {
    var pbuf: [2048]u8 = undefined;
    const pz = std.fmt.bufPrintSentinel(&pbuf, "{s}", .{path}, 0) catch return 0;
    var raw: [1024]u8 = undefined;
    const n = getxattr(pz, TAG_XATTR, &raw, raw.len, 0, XATTR_NOFOLLOW);
    if (n <= 0) return 0;
    const data = raw[0..@intCast(n)];
    var mask: u8 = 0;
    for (finder_tags) |t| {
        if (containsCaseFold(data, t.name)) {
            mask |= @as(u8, 1) << t.bit;
        }
    }
    return mask;
}

pub fn writeTagMask(path: []const u8, mask: u8) bool {
    var pbuf: [2048]u8 = undefined;
    const pz = std.fmt.bufPrintSentinel(&pbuf, "{s}", .{path}, 0) catch return false;
    if (mask == 0) {
        _ = removexattr(pz, TAG_XATTR, XATTR_NOFOLLOW);
        return true;
    }
    const pool = objc.Pool.push();
    defer pool.pop();
    const arr = objc.msg(objc.Object, objc.class("NSMutableArray"), "array", .{});
    for (finder_tags) |t| {
        if ((mask & (@as(u8, 1) << t.bit)) != 0) {
            var sbuf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&sbuf, "{s}\n{d}", .{ t.name, @as(u8, 1) + t.bit }) catch continue;
            objc.msg(void, arr, "addObject:", .{objc.nsString(s)});
        }
    }
    const fmt_bin: objc.NSUInteger = 200;
    const data = objc.msg(
        ?objc.Object,
        objc.class("NSPropertyListSerialization"),
        "dataWithPropertyList:format:options:error:",
        .{ arr, fmt_bin, @as(objc.NSUInteger, 0), @as(?*anyopaque, null) },
    ) orelse return false;
    const len = objc.msg(objc.NSUInteger, data, "length", .{});
    const ptr = objc.msg([*]const u8, data, "bytes", .{});
    return setxattr(pz, TAG_XATTR, ptr, len, 0, XATTR_NOFOLLOW) == 0;
}

fn containsCaseFold(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    const limit = haystack.len - needle.len + 1;
    for (0..limit) |i| {
        var ok = true;
        for (0..needle.len) |j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}
