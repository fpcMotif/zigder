const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const objc = nanoui.objc;

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

const gpa = std.heap.smp_allocator;
const premultiplied_bgra: u32 = 2 | (2 << 12);
const pdf_crop_box: c_int = 1;

pub const Kind = enum { pdf, image };

const Drawn = struct { bgra: []u8, w: u32, h: u32 };

pub const Shown = struct { bgra: []const u8, w: u32, h: u32, page: u32, pages: u32, key: u64 };

var key: u64 = 0;
var page: u32 = 0;
var pages: u32 = 0;
var drawn: ?Drawn = null;
var drawn_page: u32 = 0;
var tried = false;
var retired: ?[]u8 = null;

pub fn kindOf(path: []const u8) ?Kind {
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".pdf")) return .pdf;
    for ([_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".heic", ".webp", ".tiff", ".tif", ".bmp" }) |image_ext| {
        if (std.ascii.eqlIgnoreCase(ext, image_ext)) return .image;
    }
    return null;
}

pub fn pageAfter(current: u32, count: u32, delta: i32) u32 {
    if (count == 0) return 0;
    const wanted = @as(i64, current) + delta;
    return @intCast(std.math.clamp(wanted, 0, @as(i64, count) - 1));
}

pub fn turn(delta: i32) void {
    page = pageAfter(page, pages, delta);
}

pub fn show(path: []const u8, mtime: u32, max_w: u32, max_h: u32) ?Shown {
    if (comptime ui.portable) return null;
    const kind = kindOf(path) orelse return null;
    const wanted = std.hash.Wyhash.hash(mtime, path);
    if (wanted != key) {
        key = wanted;
        page = 0;
        pages = 0;
        tried = false;
    }
    if (!tried or drawn_page != page) {
        if (retired) |old| gpa.free(old);
        retired = if (drawn) |d| d.bgra else null;
        drawn = switch (kind) {
            .pdf => pdfPage(path, page, &pages, max_w, max_h),
            .image => image(path, max_w, max_h),
        };
        drawn_page = page;
        tried = true;
    }
    const d = drawn orelse return null;
    return .{ .bgra = d.bgra, .w = d.w, .h = d.h, .page = page, .pages = pages, .key = key };
}

const Canvas = struct {
    ctx: *anyopaque,
    out: Drawn,

    fn open(w: u32, h: u32) ?Canvas {
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

fn pdfPage(path: []const u8, index: u32, count: *u32, max_w: u32, max_h: u32) ?Drawn {
    const pool = objc.Pool.push();
    defer pool.pop();
    const url = objc.msg(?objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(path)}) orelse return null;
    const doc = CGPDFDocumentCreateWithURL(url) orelse return null;
    defer CGPDFDocumentRelease(doc);
    count.* = @intCast(@min(CGPDFDocumentGetNumberOfPages(doc), std.math.maxInt(u32)));
    const pdf_page = CGPDFDocumentGetPage(doc, @as(usize, index) + 1) orelse return null;
    const box = CGPDFPageGetBoxRect(pdf_page, pdf_crop_box);
    const sideways = @mod(CGPDFPageGetRotationAngle(pdf_page), 180) != 0;
    const box_w = if (sideways) box.size.height else box.size.width;
    const box_h = if (sideways) box.size.width else box.size.height;
    if (box_w < 1 or box_h < 1) return null;
    const scale = fit(box_w, box_h, max_w, max_h, true);
    const canvas = Canvas.open(@intFromFloat(@round(box_w * scale)), @intFromFloat(@round(box_h * scale))) orelse return null;
    defer CGContextRelease(canvas.ctx);
    CGContextSetRGBFillColor(canvas.ctx, 1, 1, 1, 1);
    CGContextFillRect(canvas.ctx, canvas.frame());
    CGContextScaleCTM(canvas.ctx, scale, scale);
    CGContextConcatCTM(canvas.ctx, CGPDFPageGetDrawingTransform(pdf_page, pdf_crop_box, .{ .size = .{ .width = box_w, .height = box_h } }, 0, true));
    CGContextDrawPDFPage(canvas.ctx, pdf_page);
    return canvas.out;
}

fn image(path: []const u8, max_w: u32, max_h: u32) ?Drawn {
    const pool = objc.Pool.push();
    defer pool.pop();
    const ns_image = objc.msg(?objc.Object, objc.alloc("NSImage"), "initWithContentsOfFile:", .{objc.nsString(path)}) orelse return null;
    defer objc.release(ns_image);
    const cg = objc.msg(?*anyopaque, ns_image, "CGImageForProposedRect:context:hints:", .{ @as(?*objc.CGRect, null), @as(?objc.Object, null), @as(?objc.Object, null) }) orelse return null;
    const w: f64 = @floatFromInt(CGImageGetWidth(cg));
    const h: f64 = @floatFromInt(CGImageGetHeight(cg));
    if (w < 1 or h < 1) return null;
    const scale = fit(w, h, max_w, max_h, false);
    const canvas = Canvas.open(@intFromFloat(@max(1, @round(w * scale))), @intFromFloat(@max(1, @round(h * scale)))) orelse return null;
    defer CGContextRelease(canvas.ctx);
    CGContextDrawImage(canvas.ctx, canvas.frame(), cg);
    return canvas.out;
}
