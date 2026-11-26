const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const fs_kind = @import("kind.zig");

const Affine = extern struct { a: f64, b: f64, c: f64, d: f64, tx: f64, ty: f64 };

extern "c" fn CGColorSpaceCreateDeviceRGB() ?*anyopaque;
extern "c" fn CGColorSpaceRelease(space: *anyopaque) void;
extern "c" fn CGBitmapContextCreate(data: ?*anyopaque, w: usize, h: usize, bpc: usize, bpr: usize, space: ?*anyopaque, info: u32) ?*anyopaque;
extern "c" fn CGContextRelease(ctx: *anyopaque) void;
extern "c" fn CGContextDrawImage(ctx: *anyopaque, rect: objc.CGRect, image: *anyopaque) void;
extern "c" fn CGContextSetRGBFillColor(ctx: *anyopaque, r: f64, g: f64, b: f64, a: f64) void;
extern "c" fn CGContextFillRect(ctx: *anyopaque, rect: objc.CGRect) void;
extern "c" fn CGContextScaleCTM(ctx: *anyopaque, sx: f64, sy: f64) void;
extern "c" fn CGContextConcatCTM(ctx: *anyopaque, transform: Affine) void;
extern "c" fn CGContextDrawPDFPage(ctx: *anyopaque, page: *anyopaque) void;
extern "c" fn CGImageGetWidth(image: *anyopaque) usize;
extern "c" fn CGImageGetHeight(image: *anyopaque) usize;
extern "c" fn CGPDFDocumentCreateWithURL(url: objc.Object) ?*anyopaque;
extern "c" fn CGPDFDocumentRelease(doc: *anyopaque) void;
extern "c" fn CGPDFDocumentGetNumberOfPages(doc: *anyopaque) usize;
extern "c" fn CGPDFDocumentGetPage(doc: *anyopaque, number: usize) ?*anyopaque;
extern "c" fn CGPDFPageGetBoxRect(page: *anyopaque, box: c_int) objc.CGRect;
extern "c" fn CGPDFPageGetRotationAngle(page: *anyopaque) c_int;
extern "c" fn CGPDFPageGetDrawingTransform(page: *anyopaque, box: c_int, rect: objc.CGRect, rotate: c_int, preserve_aspect: bool) Affine;

extern "c" fn clock_gettime_nsec_np(clock_id: c_int) u64;
const clock_uptime_raw: c_int = 8;
const premultiplied_bgra: u32 = 2 | (2 << 12);
const pdf_crop_box: c_int = 1;
const small_side: u32 = 32;
const large_side: u32 = 128;
const huge_side: u32 = 256;
pub const small_max_pt: f32 = 20;
const large_max_pt: f32 = 64;

pub const Bitmap = struct {
    bgra: []u8,
    w: u32,
    h: u32,
};

pub const PdfResult = struct {
    bitmap: ?Bitmap = null,
    pages: u32 = 0,
};

pub const IconPixels = struct {
    key: u64,
    bgra: []const u8,
    side: u32,
};

pub const Shown = struct {
    bgra: []const u8,
    w: u32,
    h: u32,
    page: u32,
    pages: u32,
    key: u64,
};

pub const Rasterizer = struct {
    ctx: ?*anyopaque = null,
    icon: *const fn (?*anyopaque, std.mem.Allocator, []const u8, u32) ?[]u8 = nativeIcon,
    pdf_page: *const fn (?*anyopaque, std.mem.Allocator, []const u8, u32, u32, u32) PdfResult = nativePdfPage,
    image: *const fn (?*anyopaque, std.mem.Allocator, []const u8, u32, u32) ?Bitmap = nativeImage,
};

pub fn cacheKey(full: []const u8, container: bool) u64 {
    const ext = fs_kind.extOfName(std.fs.path.basename(full));
    if (container or ext.len == 0) return std.hash.Wyhash.hash(1, full);
    var hasher = std.hash.Wyhash.init(2);
    for (ext) |ch| hasher.update(&.{std.ascii.toLower(ch)});
    return hasher.final();
}

pub fn sideForPt(pt: f32) u32 {
    if (pt <= small_max_pt) return small_side;
    if (pt <= large_max_pt) return large_side;
    return huge_side;
}

pub fn pageAfter(current: u32, count: u32, delta: i32) u32 {
    if (count == 0) return 0;
    const wanted = @as(i64, current) + delta;
    return @intCast(std.math.clamp(wanted, 0, @as(i64, count) - 1));
}

pub fn rasterizeIcon(gpa: std.mem.Allocator, full: []const u8, side: u32) ?[]u8 {
    return nativeIcon(null, gpa, full, side);
}

pub const IconCache = struct {
    gpa: std.mem.Allocator,
    live: std.AutoHashMapUnmanaged(u64, ?[]u8) = .empty,
    retired: std.AutoHashMapUnmanaged(u64, ?[]u8) = .empty,
    live_bytes: usize = 0,
    live_bytes_max: usize = 24 * 1024 * 1024,
    frame_budget_ns: u64 = 2 * std.time.ns_per_ms,
    frame_spent_ns: u64 = 0,
    frame_draws: u32 = 0,
    deferred: bool = false,
    rasterizer: Rasterizer = .{},

    fn freeMap(gpa: std.mem.Allocator, map: *std.AutoHashMapUnmanaged(u64, ?[]u8)) void {
        var it = map.valueIterator();
        while (it.next()) |px| if (px.*) |bytes| gpa.free(bytes);
        map.deinit(gpa);
    }

    pub fn deinit(c: *IconCache) void {
        freeMap(c.gpa, &c.live);
        freeMap(c.gpa, &c.retired);
        c.live_bytes = 0;
    }

    pub fn beginFrame(c: *IconCache) void {
        c.frame_spent_ns = 0;
        c.frame_draws = 0;
        c.deferred = false;
        if (c.live_bytes < c.live_bytes_max) return;
        freeMap(c.gpa, &c.retired);
        c.retired = c.live;
        c.live = .empty;
        c.live_bytes = 0;
    }

    pub fn lookup(c: *IconCache, full: []const u8, container: bool, pt: f32) ?IconPixels {
        if ((comptime nanoui.ui.portable) and c.rasterizer.icon == nativeIcon) return null;
        const side = sideForPt(pt);
        const key = cacheKey(full, container) ^ side;
        if (c.live.get(key)) |found| {
            const bytes = found orelse return null;
            return .{ .key = key, .bgra = bytes, .side = side };
        }
        if (c.frame_draws > 0 and c.frame_spent_ns >= c.frame_budget_ns) {
            c.deferred = true;
            return null;
        }
        const started = clock_gettime_nsec_np(clock_uptime_raw);
        const drawn = c.rasterizer.icon(c.rasterizer.ctx, c.gpa, full, side);
        c.frame_spent_ns += clock_gettime_nsec_np(clock_uptime_raw) - started;
        c.frame_draws += 1;
        c.live.put(c.gpa, key, drawn) catch {
            if (drawn) |bytes| c.gpa.free(bytes);
            return null;
        };
        const bytes = drawn orelse return null;
        c.live_bytes += bytes.len;
        return .{ .key = key, .bgra = bytes, .side = side };
    }
};

pub const PreviewCache = struct {
    gpa: std.mem.Allocator,
    key: u64 = 0,
    page: u32 = 0,
    pages: u32 = 0,
    drawn: ?Bitmap = null,
    drawn_page: u32 = 0,
    tried: bool = false,
    retired: ?[]u8 = null,
    rasterizer: Rasterizer = .{},

    pub fn deinit(c: *PreviewCache) void {
        if (c.drawn) |d| c.gpa.free(d.bgra);
        if (c.retired) |old| c.gpa.free(old);
        c.* = .{ .gpa = c.gpa, .rasterizer = c.rasterizer };
    }

    pub fn turn(c: *PreviewCache, delta: i32) bool {
        const next = pageAfter(c.page, c.pages, delta);
        const moved = next != c.page;
        c.page = next;
        return moved;
    }

    pub fn show(c: *PreviewCache, path: []const u8, kind_byte: u8, mtime: u32, max_w: u32, max_h: u32) ?Shown {
        const kind = fs_kind.classify(std.fs.path.basename(path), kind_byte).preview orelse return null;
        if (comptime nanoui.ui.portable) {
            if (kind == .pdf and c.rasterizer.pdf_page == nativePdfPage) return null;
            if (kind == .image and c.rasterizer.image == nativeImage) return null;
        }
        const wanted = std.hash.Wyhash.hash(mtime, path);
        if (wanted != c.key) {
            c.key = wanted;
            c.page = 0;
            c.pages = 0;
            c.tried = false;
        }
        if (!c.tried or c.drawn_page != c.page) {
            if (c.retired) |old| c.gpa.free(old);
            c.retired = if (c.drawn) |d| d.bgra else null;
            switch (kind) {
                .pdf => {
                    const res = c.rasterizer.pdf_page(c.rasterizer.ctx, c.gpa, path, c.page, max_w, max_h);
                    c.pages = res.pages;
                    c.drawn = res.bitmap;
                },
                .image => {
                    c.pages = 0;
                    c.drawn = c.rasterizer.image(c.rasterizer.ctx, c.gpa, path, max_w, max_h);
                },
            }
            c.drawn_page = c.page;
            c.tried = true;
        }
        const d = c.drawn orelse return null;
        return .{ .bgra = d.bgra, .w = d.w, .h = d.h, .page = c.page, .pages = c.pages, .key = c.key };
    }
};

pub const MediaCache = struct {
    icons: IconCache,
    preview: PreviewCache,

    pub fn init(gpa: std.mem.Allocator) MediaCache {
        return .{
            .icons = .{ .gpa = gpa },
            .preview = .{ .gpa = gpa },
        };
    }

    pub fn deinit(m: *MediaCache) void {
        m.icons.deinit();
        m.preview.deinit();
    }

    pub fn beginFrame(m: *MediaCache) void {
        m.icons.beginFrame();
    }

    pub fn setRasterizer(m: *MediaCache, r: Rasterizer) void {
        m.icons.rasterizer = r;
        m.preview.rasterizer = r;
    }
};

const Canvas = struct {
    ctx: *anyopaque,
    out: Bitmap,

    fn open(gpa: std.mem.Allocator, w: u32, h: u32) ?Canvas {
        if (w == 0 or h == 0) return null;
        const bytes = gpa.alloc(u8, @as(usize, w) * h * 4) catch return null;
        @memset(bytes, 0);
        const space = CGColorSpaceCreateDeviceRGB() orelse {
            gpa.free(bytes);
            return null;
        };
        defer CGColorSpaceRelease(space);
        const ctx = CGBitmapContextCreate(bytes.ptr, w, h, 8, @as(usize, w) * 4, space, premultiplied_bgra) orelse {
            gpa.free(bytes);
            return null;
        };
        return .{ .ctx = ctx, .out = .{ .bgra = bytes, .w = w, .h = h } };
    }

    fn frame(canvas: Canvas) objc.CGRect {
        return .{ .size = .{ .width = @floatFromInt(canvas.out.w), .height = @floatFromInt(canvas.out.h) } };
    }
};

fn fit(w: f64, h: f64, max_w: u32, max_h: u32, enlarge: bool) f64 {
    const scale = @min(@as(f64, @floatFromInt(max_w)) / w, @as(f64, @floatFromInt(max_h)) / h);
    return if (enlarge) scale else @min(1, scale);
}

fn nativeIcon(_: ?*anyopaque, gpa: std.mem.Allocator, full: []const u8, side: u32) ?[]u8 {
    if (comptime nanoui.ui.portable) return null;
    const pool = objc.Pool.push();
    defer pool.pop();
    const workspace = objc.msg(?objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{}) orelse return null;
    const image = objc.msg(?objc.Object, workspace, "iconForFile:", .{objc.nsString(full)}) orelse return null;
    var rect: objc.CGRect = .{ .size = .{ .width = @floatFromInt(side), .height = @floatFromInt(side) } };
    const cg = objc.msg(?*anyopaque, image, "CGImageForProposedRect:context:hints:", .{ &rect, @as(?objc.Object, null), @as(?objc.Object, null) }) orelse return null;
    const canvas = Canvas.open(gpa, side, side) orelse return null;
    defer CGContextRelease(canvas.ctx);
    CGContextDrawImage(canvas.ctx, canvas.frame(), cg);
    return canvas.out.bgra;
}

fn nativePdfPage(_: ?*anyopaque, gpa: std.mem.Allocator, path: []const u8, index: u32, max_w: u32, max_h: u32) PdfResult {
    if (comptime nanoui.ui.portable) return .{};
    const pool = objc.Pool.push();
    defer pool.pop();
    const url = objc.msg(?objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(path)}) orelse return .{};
    const doc = CGPDFDocumentCreateWithURL(url) orelse return .{};
    defer CGPDFDocumentRelease(doc);
    const pages: u32 = @intCast(@min(CGPDFDocumentGetNumberOfPages(doc), std.math.maxInt(u32)));
    const pdf_page = CGPDFDocumentGetPage(doc, @as(usize, index) + 1) orelse return .{ .pages = pages };
    const box = CGPDFPageGetBoxRect(pdf_page, pdf_crop_box);
    const sideways = @mod(CGPDFPageGetRotationAngle(pdf_page), 180) != 0;
    const box_w = if (sideways) box.size.height else box.size.width;
    const box_h = if (sideways) box.size.width else box.size.height;
    if (box_w < 1 or box_h < 1) return .{ .pages = pages };
    const scale = fit(box_w, box_h, max_w, max_h, true);
    const canvas = Canvas.open(gpa, @intFromFloat(@round(box_w * scale)), @intFromFloat(@round(box_h * scale))) orelse return .{ .pages = pages };
    defer CGContextRelease(canvas.ctx);
    CGContextSetRGBFillColor(canvas.ctx, 1, 1, 1, 1);
    CGContextFillRect(canvas.ctx, canvas.frame());
    CGContextScaleCTM(canvas.ctx, scale, scale);
    CGContextConcatCTM(canvas.ctx, CGPDFPageGetDrawingTransform(pdf_page, pdf_crop_box, .{ .size = .{ .width = box_w, .height = box_h } }, 0, true));
    CGContextDrawPDFPage(canvas.ctx, pdf_page);
    return .{ .bitmap = canvas.out, .pages = pages };
}

fn nativeImage(_: ?*anyopaque, gpa: std.mem.Allocator, path: []const u8, max_w: u32, max_h: u32) ?Bitmap {
    if (comptime nanoui.ui.portable) return null;
    const pool = objc.Pool.push();
    defer pool.pop();
    const ns_image = objc.msg(?objc.Object, objc.alloc("NSImage"), "initWithContentsOfFile:", .{objc.nsString(path)}) orelse return null;
    defer objc.release(ns_image);
    const cg = objc.msg(?*anyopaque, ns_image, "CGImageForProposedRect:context:hints:", .{ @as(?*objc.CGRect, null), @as(?objc.Object, null), @as(?objc.Object, null) }) orelse return null;
    const w: f64 = @floatFromInt(CGImageGetWidth(cg));
    const h: f64 = @floatFromInt(CGImageGetHeight(cg));
    if (w < 1 or h < 1) return null;
    const scale = fit(w, h, max_w, max_h, false);
    const canvas = Canvas.open(gpa, @intFromFloat(@max(1, @round(w * scale))), @intFromFloat(@max(1, @round(h * scale)))) orelse return null;
    defer CGContextRelease(canvas.ctx);
    CGContextDrawImage(canvas.ctx, canvas.frame(), cg);
    return canvas.out;
}
