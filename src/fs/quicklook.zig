const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const fmt = @import("../index/fmt.zig");
const volumes = @import("volumes.zig");
const walk = @import("../index/walk.zig");
const fs_kind = @import("kind.zig");

extern "c" fn dlopen(path: [*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn lstat(path: [*:0]const u8, buf: *std.c.Stat) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;

pub const InspectorPreview = struct {
    valid: bool = false,
    is_dir: bool = false,
    kind: u8 = walk.KIND_FILE,
    size: u64 = 0,
    alloc: u64 = 0,
    mtime: u32 = 0,
    created: u32 = 0,
    last_opened: u32 = 0,
    last_opened_due: bool = false,
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

    pub fn load(path: []const u8, dir_totals: ?fmt.Totals) InspectorPreview {
        var out: InspectorPreview = .{};
        var pbuf: [2048]u8 = undefined;
        const pz = std.fmt.bufPrintSentinel(&pbuf, "{s}", .{path}, 0) catch return out;
        var st: std.c.Stat = undefined;
        if (lstat(pz, &st) != 0) return out;
        out.valid = true;
        out.kind = walk.kindFromMode(st.mode);
        out.is_dir = out.kind == walk.KIND_DIR;
        out.size = @intCast(@max(st.size, 0));
        out.alloc = @as(u64, @intCast(@max(st.blocks, 0))) * 512;
        const mt = st.mtimespec.sec;
        out.mtime = if (mt <= 0) 0 else @intCast(@min(mt, std.math.maxInt(u32)));
        const born = st.birthtimespec.sec;
        out.created = if (born <= 0) 0 else @intCast(@min(born, std.math.maxInt(u32)));
        if (spotlight_warming.load(.acquire)) {
            out.last_opened_due = true;
        } else {
            out.last_opened = lastOpened(path);
        }
        out.tag_mask = volumes.readTagMask(path);

        const nm = std.fs.path.basename(path);
        const kind_str = fs_kind.classify(nm, out.kind).label;
        const klen = @min(kind_str.len, out.kind_buf.len);
        @memcpy(out.kind_buf[0..klen], kind_str[0..klen]);
        out.kind_len = klen;

        if (out.is_dir) {
            if (dir_totals) |tot| {
                out.size = tot.bytes;
                out.alloc = tot.allocated;
                out.dir_items = tot.visible;
            }
            return out;
        }
        if (out.kind != walk.KIND_FILE or out.size == 0) return out;

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

    pub fn finishLastOpened(p: *InspectorPreview, path: []const u8) void {
        if (!p.last_opened_due or spotlight_warming.load(.acquire)) return;
        p.last_opened_due = false;
        p.last_opened = lastOpened(path);
    }
};

pub var spotlight_warming: std.atomic.Value(bool) = .init(false);

pub const Wake = struct {
    ctx: ?*anyopaque,
    func: *const fn (?*anyopaque) void,
};

pub fn warmLastOpened(wake: Wake) void {
    spotlight_warming.store(true, .release);
    const th = std.Thread.spawn(.{}, warmMain, .{wake}) catch {
        spotlight_warming.store(false, .release);
        return;
    };
    th.detach();
}

fn warmMain(wake: Wake) void {
    _ = lastOpened("/");
    spotlight_warming.store(false, .release);
    wake.func(wake.ctx);
}

extern "c" fn MDItemCreate(allocator: ?*anyopaque, path: objc.Object) ?*anyopaque;
extern "c" fn MDItemCopyAttribute(item: *anyopaque, name: *anyopaque) ?*anyopaque;
extern "c" fn CFDateGetAbsoluteTime(date: *anyopaque) f64;
extern "c" fn CFRelease(object: *anyopaque) void;
extern "c" const kMDItemLastUsedDate: *anyopaque;

const cf_epoch_offset: f64 = 978_307_200;

fn lastOpened(path: []const u8) u32 {
    const pool = objc.Pool.push();
    defer pool.pop();
    const item = MDItemCreate(null, objc.nsString(path)) orelse return 0;
    defer CFRelease(item);
    const date = MDItemCopyAttribute(item, kMDItemLastUsedDate) orelse return 0;
    defer CFRelease(date);
    const unix = CFDateGetAbsoluteTime(date) + cf_epoch_offset;
    if (unix <= 0 or unix > std.math.maxInt(u32)) return 0;
    return @intFromFloat(unix);
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

pub const Panel = struct {
    ctx: ?*anyopaque = null,
    is_visible: *const fn (?*anyopaque, *const QuickLook) bool = QuickLook.nativeIsVisible,
    show: *const fn (?*anyopaque, *QuickLook) void = QuickLook.nativeShow,
    hide: *const fn (?*anyopaque, *QuickLook) void = QuickLook.nativeHide,
    reload: *const fn (?*anyopaque, *QuickLook) void = QuickLook.nativeReload,
};

pub const QuickLook = struct {
    gpa: std.mem.Allocator,
    headless: bool = false,
    items: std.ArrayList([]u8) = .empty,
    bridge: ?objc.Object = null,
    ql_loaded: bool = false,
    panel: Panel = .{},

    pub fn deinit(q: *QuickLook) void {
        for (q.items.items) |p| q.gpa.free(p);
        q.items.deinit(q.gpa);
        if (q.bridge) |b| objc.release(b);
    }

    pub fn setPanel(q: *QuickLook, panel: Panel) void {
        q.panel = panel;
    }

    pub fn isVisible(q: *const QuickLook) bool {
        if (q.headless) return false;
        return q.panel.is_visible(q.panel.ctx, q);
    }

    pub fn close(q: *QuickLook) void {
        if (q.headless) return;
        if (q.panel.is_visible(q.panel.ctx, q)) {
            q.panel.hide(q.panel.ctx, q);
        }
    }

    pub fn toggle(q: *QuickLook, paths: []const []const u8) void {
        if (q.headless) return;
        if (q.panel.is_visible(q.panel.ctx, q)) {
            q.panel.hide(q.panel.ctx, q);
            return;
        }
        if (paths.len == 0) return;
        q.setItems(paths);
        q.panel.show(q.panel.ctx, q);
    }

    pub fn updateIfVisible(q: *QuickLook, paths: []const []const u8) void {
        if (q.headless) return;
        if (!q.panel.is_visible(q.panel.ctx, q)) return;
        q.setItems(paths);
        q.panel.reload(q.panel.ctx, q);
    }

    fn nativeIsVisible(_: ?*anyopaque, q: *const QuickLook) bool {
        if (!q.ql_loaded) return false;
        const panel_cls = objc.class("QLPreviewPanel");
        if (!objc.msg(objc.BOOL, panel_cls, "sharedPreviewPanelExists", .{})) return false;
        const panel = objc.msg(objc.Object, panel_cls, "sharedPreviewPanel", .{});
        return objc.msg(objc.BOOL, panel, "isVisible", .{});
    }

    fn nativeShow(_: ?*anyopaque, q: *QuickLook) void {
        _ = q.ensureBridge() orelse return;
        const panel = objc.msg(objc.Object, objc.class("QLPreviewPanel"), "sharedPreviewPanel", .{});
        objc.msg(void, panel, "setDataSource:", .{q.bridge.?});
        objc.msg(void, panel, "setDelegate:", .{q.bridge.?});
        objc.msg(void, panel, "reloadData", .{});
        objc.msg(void, panel, "makeKeyAndOrderFront:", .{@as(?objc.Object, null)});
    }

    fn nativeHide(_: ?*anyopaque, q: *QuickLook) void {
        if (!q.ql_loaded) return;
        const panel_cls = objc.class("QLPreviewPanel");
        if (!objc.msg(objc.BOOL, panel_cls, "sharedPreviewPanelExists", .{})) return;
        const panel = objc.msg(objc.Object, panel_cls, "sharedPreviewPanel", .{});
        objc.msg(void, panel, "orderOut:", .{@as(?objc.Object, null)});
    }

    fn nativeReload(_: ?*anyopaque, q: *QuickLook) void {
        if (!q.ql_loaded) return;
        const panel_cls = objc.class("QLPreviewPanel");
        if (!objc.msg(objc.BOOL, panel_cls, "sharedPreviewPanelExists", .{})) return;
        const panel = objc.msg(objc.Object, panel_cls, "sharedPreviewPanel", .{});
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
