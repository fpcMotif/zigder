const nanoui = @import("nanoui");
const measure = @import("../measure.zig");

pub const initial_atlas_side: u32 = 512;
pub const max_decoded_bytes: usize = 2 * 1024 * 1024;

pub fn tuneImages(im: anytype, r: anytype) void {
    im.limits.decoded_bytes = max_decoded_bytes;
    if (comptime nanoui.ui.portable) return;
    const R = @TypeOf(r.*);
    if (im.sink == null) {
        im.sink = .{ .ctx = r, .upload = R.uploadImage };
    }
    if (im.pixels.len > 0) {
        im.gpa.free(im.pixels);
        im.pixels = &.{};
    }
    if (im.side > initial_atlas_side and im.shelf_y + im.shelf_h <= initial_atlas_side / 2) {
        im.side = initial_atlas_side;
        im.invalidateAtlas();
        if (r.images_texture) |tex| {
            if (r.images_side > initial_atlas_side) {
                r.waitIdle();
                nanoui.objc.release(tex);
                r.images_texture = null;
                r.images_side = 0;
            }
        }
    }
}

pub fn restRenderer(r: anytype) void {
    if (comptime nanoui.ui.portable) return;
    const R = @TypeOf(r.*);
    r.waitIdle();
    const pool = nanoui.objc.Pool.push();
    defer pool.pop();
    for (&r.buffers, &r.capacities) |*buf, *cap| {
        if (buf.*) |b| {
            nanoui.objc.release(b);
            buf.* = null;
            cap.* = 0;
        }
    }
    for (r.layer_textures.items) |t| nanoui.objc.release(t);
    r.layer_textures.clearRetainingCapacity();
    r.layer_w = 0;
    r.layer_h = 0;
    r.glass.releaseTextures();
    const Proxy = struct {
        fn commandBuffer(self_obj: nanoui.objc.Object, _: nanoui.objc.SEL) callconv(.c) nanoui.objc.Object {
            const r_ptr = nanoui.objc.getZig(R, self_obj).?;
            const real_q = nanoui.objc.msg(nanoui.objc.Object, r_ptr.device, "newCommandQueue", .{});
            r_ptr.queue = real_q;
            nanoui.objc.autorelease(self_obj);
            return nanoui.objc.msg(nanoui.objc.Object, real_q, "commandBuffer", .{});
        }
    };
    const cls = nanoui.objc.defineClass(.{
        .name = "ZigderRestQueue",
        .methods = &.{
            .{ .name = "commandBuffer", .imp = @ptrCast(&Proxy.commandBuffer), .types = "@@:" },
        },
    });
    if (nanoui.objc.getZig(R, r.queue) == null) {
        const old_q = r.queue;
        const proxy = nanoui.objc.msg(nanoui.objc.Object, nanoui.objc.msg(nanoui.objc.Object, cls, "alloc", .{}), "init", .{});
        nanoui.objc.setZig(proxy, r);
        r.queue = proxy;
        nanoui.objc.release(old_q);
    }
}

pub const IdleRest = struct {
    surface: ?*nanoui.Surface = null,
    last_frame_ns: u64 = 0,
    timer_active: bool = false,
    stopped: bool = false,

    pub fn install(self: *IdleRest, win: *nanoui.Window) void {
        if (comptime nanoui.ui.portable) return;
        const surf = win.surface orelse return;
        tuneImages(&surf.text.images, &surf.renderer);
        self.surface = surf;
        surf.after_frame_ctx = self;
        surf.after_frame = onAfterFrame;
        self.last_frame_ns = measure.nanos();
        self.armTimer();
    }

    fn armTimer(self: *IdleRest) void {
        if (self.stopped or self.timer_active) return;
        self.timer_active = true;
        nanoui.App.after(250, self, onTimer);
    }

    fn onAfterFrame(ctx: ?*anyopaque, surf: *nanoui.Surface) bool {
        const self: *IdleRest = @ptrCast(@alignCast(ctx orelse return false));
        if (self.stopped or surf.dead) return false;
        self.last_frame_ns = measure.nanos();
        self.armTimer();
        return false;
    }

    fn onTimer(ctx: ?*anyopaque) callconv(.c) void {
        const self: *IdleRest = @ptrCast(@alignCast(ctx orelse return));
        self.timer_active = false;
        if (self.stopped) return;
        const surf = self.surface orelse return;
        if (surf.dead) return;
        if (surf.ctx.animating or (measure.nanos() -| self.last_frame_ns) < 240_000_000) {
            self.armTimer();
            return;
        }
        if (nanoui.objc.getZig(@TypeOf(surf.renderer), surf.renderer.queue) != null) return;
        surf.text.images.trimDecoded();
        restRenderer(&surf.renderer);
        measure.releaseHeap();
    }
};
