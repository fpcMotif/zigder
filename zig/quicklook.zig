const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const walk = @import("walk.zig");
const live_mod = @import("live.zig");
const volumes = @import("volumes.zig");
const fs_entry = @import("fs_entry.zig");

extern "c" fn dlopen(path: [*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn lstat(path: [*:0]const u8, buf: *std.c.Stat) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;

pub const InspectorPreview = struct {
    valid: bool = false,
    is_dir: bool = false,
    size: u64 = 0,
    alloc: u64 = 0,
    mtime: u32 = 0,
    mode: u16 = 0,
    dir_items: u64 = 0,
    tag_mask: u8 = 0,
    kind_buf: [48]u8 = undefined,
    kind_len: usize = 0,
    snippet: [4096]u8 = undefined,
    snippet_len: usize = 0,
    is_text: bool = false,
    image_w: u32 = 0,
    image_h: u32 = 0,

    pub fn kindText(p: *const InspectorPreview) []const u8 {
        return p.kind_buf[0..p.kind_len];
    }

    pub fn snippetText(p: *const InspectorPreview) []const u8 {
        return p.snippet[0..p.snippet_len];
    }

    pub fn load(path: []const u8, live_opt: ?*const live_mod.Live) InspectorPreview {
        var out: InspectorPreview = .{};
        var pbuf: [2048]u8 = undefined;
        const pz = std.fmt.bufPrintSentinel(&pbuf, "{s}", .{path}, 0) catch return out;
        var st: std.c.Stat = undefined;
        if (lstat(pz, &st) != 0) return out;
        out.valid = true;
        out.mode = @intCast(st.mode & 0o7777);
        const ftype = st.mode & 0o170000;
        out.is_dir = ftype == 0o040000;
        out.size = @intCast(@max(st.size, 0));
        out.alloc = @as(u64, @intCast(@max(st.blocks, 0))) * 512;
        const mt = st.mtimespec.sec;
        out.mtime = if (mt <= 0) 0 else @intCast(@min(mt, std.math.maxInt(u32)));
        out.tag_mask = volumes.readTagMask(path);

        const nm = std.fs.path.basename(path);
        const kind_str = describeKind(nm, ftype);
        const klen = @min(kind_str.len, out.kind_buf.len);
        @memcpy(out.kind_buf[0..klen], kind_str[0..klen]);
        out.kind_len = klen;

        if (out.is_dir) {
            if (live_opt) |live| {
                if (live.totals(path)) |tot| {
                    out.size = tot.bytes;
                    out.alloc = tot.allocated;
                    out.dir_items = tot.visible;
                }
            }
            return out;
        }
        if (ftype != 0o100000 or out.size == 0) return out;

        const fd = open(pz, 0);
        if (fd < 0) return out;
        defer _ = close(fd);
        const n = read(fd, &out.snippet, out.snippet.len);
        if (n <= 0) return out;
        const bytes = out.snippet[0..@intCast(n)];
        parseImageHeader(bytes, &out.image_w, &out.image_h);
        if (out.image_w == 0 and std.mem.indexOfScalar(u8, bytes, 0) == null and std.unicode.utf8ValidateSlice(bytes)) {
            out.is_text = true;
            out.snippet_len = bytes.len;
        }
        return out;
    }
};

fn describeKind(name: []const u8, ftype: u16) []const u8 {
    if (ftype == 0o120000) return "Alias / Symlink";
    if (ftype == 0o040000) {
        if (name.len > 4 and std.ascii.eqlIgnoreCase(name[name.len - 4 ..], ".app")) return "Application";
        if (fs_entry.isPackageName(name)) return "Package";
        return "Folder";
    }
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "Document";
    const ext = name[dot + 1 ..];
    if (std.ascii.eqlIgnoreCase(ext, "zig")) return "Zig Source";
    if (std.ascii.eqlIgnoreCase(ext, "rs")) return "Rust Source";
    if (std.ascii.eqlIgnoreCase(ext, "md")) return "Markdown";
    if (std.ascii.eqlIgnoreCase(ext, "json")) return "JSON";
    if (std.ascii.eqlIgnoreCase(ext, "toml")) return "TOML";
    if (std.ascii.eqlIgnoreCase(ext, "png")) return "PNG Image";
    if (std.ascii.eqlIgnoreCase(ext, "jpg") or std.ascii.eqlIgnoreCase(ext, "jpeg")) return "JPEG Image";
    if (std.ascii.eqlIgnoreCase(ext, "pdf")) return "PDF Document";
    return "Document";
}

fn parseImageHeader(bytes: []const u8, w: *u32, h: *u32) void {
    const png_sig = "\x89PNG\r\n\x1a\n";
    if (bytes.len >= 24 and std.mem.eql(u8, bytes[0..8], png_sig)) {
        w.* = std.mem.readInt(u32, bytes[16..20], .big);
        h.* = std.mem.readInt(u32, bytes[20..24], .big);
        return;
    }
    if (bytes.len >= 12 and bytes[0] == 0xFF and bytes[1] == 0xD8) {
        var i: usize = 2;
        while (i + 9 < bytes.len) {
            if (bytes[i] != 0xFF) break;
            const marker = bytes[i + 1];
            if (marker == 0xC0 or marker == 0xC2) {
                h.* = std.mem.readInt(u16, bytes[i + 5 ..][0..2], .big);
                w.* = std.mem.readInt(u16, bytes[i + 7 ..][0..2], .big);
                return;
            }
            const seg_len = std.mem.readInt(u16, bytes[i + 2 ..][0..2], .big);
            if (seg_len < 2) break;
            i += 2 + seg_len;
        }
    }
}

pub const QuickLook = struct {
    gpa: std.mem.Allocator,
    headless: bool = false,
    items: std.ArrayList([]u8) = .empty,
    bridge: ?objc.Object = null,
    ql_loaded: bool = false,

    pub fn deinit(q: *QuickLook) void {
        for (q.items.items) |p| q.gpa.free(p);
        q.items.deinit(q.gpa);
        if (q.bridge) |b| objc.release(b);
    }

    pub fn toggle(q: *QuickLook, paths: []const []const u8) void {
        if (q.headless or paths.len == 0) return;
        _ = q.ensureBridge() orelse return;
        q.setItems(paths);
        const panel_cls = objc.class("QLPreviewPanel");
        const exists = objc.msg(objc.BOOL, panel_cls, "sharedPreviewPanelExists", .{});
        const panel = objc.msg(objc.Object, panel_cls, "sharedPreviewPanel", .{});
        if (exists and objc.msg(objc.BOOL, panel, "isVisible", .{})) {
            objc.msg(void, panel, "orderOut:", .{@as(?objc.Object, null)});
            return;
        }
        objc.msg(void, panel, "setDataSource:", .{q.bridge.?});
        objc.msg(void, panel, "setDelegate:", .{q.bridge.?});
        objc.msg(void, panel, "reloadData", .{});
        objc.msg(void, panel, "makeKeyAndOrderFront:", .{@as(?objc.Object, null)});
    }

    pub fn updateIfVisible(q: *QuickLook, paths: []const []const u8) void {
        if (q.headless or !q.ql_loaded) return;
        const panel_cls = objc.class("QLPreviewPanel");
        if (!objc.msg(objc.BOOL, panel_cls, "sharedPreviewPanelExists", .{})) return;
        const panel = objc.msg(objc.Object, panel_cls, "sharedPreviewPanel", .{});
        if (!objc.msg(objc.BOOL, panel, "isVisible", .{})) return;
        q.setItems(paths);
        objc.msg(void, panel, "reloadData", .{});
    }

    fn setItems(q: *QuickLook, paths: []const []const u8) void {
        for (q.items.items) |p| q.gpa.free(p);
        q.items.clearRetainingCapacity();
        for (paths) |p| {
            const dup = q.gpa.dupe(u8, p) catch continue;
            q.items.append(q.gpa, dup) catch q.gpa.free(dup);
        }
    }

    fn ensureBridge(q: *QuickLook) ?objc.Object {
        if (!q.ql_loaded) {
            if (dlopen("/System/Library/Frameworks/QuickLookUI.framework/QuickLookUI", 1) == null) return null;
            q.ql_loaded = true;
        }
        if (q.bridge) |b| return b;
        const cls = objc.defineClass(.{
            .name = "ZigderQLBridge",
            .superclass = "NSObject",
            .protocols = &.{ "QLPreviewPanelDataSource", "QLPreviewPanelDelegate" },
            .methods = &.{
                .{ .name = "numberOfPreviewItemsInPreviewPanel:", .imp = &qlCount, .types = "q@:@" },
                .{ .name = "previewPanel:previewItemAtIndex:", .imp = &qlItem, .types = "@@:@q" },
            },
        });
        const obj = objc.msg(objc.Object, objc.msg(objc.Object, cls, "alloc", .{}), "init", .{});
        objc.setZig(obj, q);
        q.bridge = obj;
        return obj;
    }
};

fn qlCount(self: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) objc.NSInteger {
    const q: *QuickLook = objc.getZig(QuickLook, self) orelse return 0;
    return @intCast(q.items.items.len);
}

fn qlItem(self: objc.Object, _: objc.SEL, _: objc.Object, index: objc.NSInteger) callconv(.c) ?objc.Object {
    const q: *QuickLook = objc.getZig(QuickLook, self) orelse return null;
    if (index < 0 or @as(usize, @intCast(index)) >= q.items.items.len) return null;
    const p = q.items.items[@intCast(index)];
    return objc.msg(objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(p)});
}
