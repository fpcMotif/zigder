const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const walk = @import("../index/walk.zig");
const index_read = @import("../index/read.zig");
const fs_entry = @import("../fs/entry.zig");
const fs_media = @import("../fs/media.zig");
const quicklook = @import("../fs/quicklook.zig");
const app_mod = @import("../app/app.zig");
const session = @import("../app/session.zig");
const commands = @import("../app/commands.zig");
const theme = @import("../ui/theme.zig");
const view_mod = @import("../ui/view.zig");
const support = @import("support.zig");

fn dummyPalette() theme.Palette {
    const black = ui.Color.black;
    return .{
        .bg = black,
        .sidebar = black,
        .surface = black,
        .chrome = black,
        .row_alt = black,
        .row_hover = black,
        .row_sel = black,
        .row_sel_muted = black,
        .border = black,
        .divider = black,
        .text = black,
        .muted = black,
        .subtle = black,
        .accent = black,
        .accent_text = black,
        .folder = black,
        .code = black,
        .badge_bg = black,
        .code_bg = black,
        .success = black,
    };
}

test "media: list, inspector, and preview share one kind table including symlinks" {
    const gpa = std.testing.allocator;
    const tmp = try support.TempDir.create("/tmp/zigder-med");
    defer tmp.cleanup();
    const root = tmp.path();

    try support.sh(
        "cd '{s}' && mkdir -p App.app sub && " ++
            "printf 'txt' > note.txt && printf 'png' > pic.png && printf 'jpg' > photo.jpg && " ++
            "printf 'doc' > doc.docx && printf 'pdf' > report.pdf && ln -s note.txt link_to_note",
        .{root},
    );

    var listing = try fs_entry.loadFolder(gpa, root, null, .name, true, true, false);
    defer listing.deinit(gpa);
    const pal = dummyPalette();

    const Expected = struct {
        name: []const u8,
        label: []const u8,
    };
    const cases = [_]Expected{
        .{ .name = "note.txt", .label = "Plain Text" },
        .{ .name = "pic.png", .label = "PNG Image" },
        .{ .name = "photo.jpg", .label = "JPEG Image" },
        .{ .name = "doc.docx", .label = "Word Document" },
        .{ .name = "report.pdf", .label = "PDF Document" },
        .{ .name = "App.app", .label = "Application" },
        .{ .name = "sub", .label = "Folder" },
        .{ .name = "link_to_note", .label = "Alias" },
    };

    var seen: usize = 0;
    var pbuf: [256]u8 = undefined;
    for (listing.entries.items) |ent| {
        const nm = listing.nameOf(ent);
        const full = index_read.joinBuf(&pbuf, root, nm) orelse return error.BadPath;
        const prev = quicklook.InspectorPreview.load(full, null);
        try std.testing.expect(prev.valid);
        try std.testing.expectEqualStrings(theme.kindLabel(&listing, ent), prev.kindText());

        for (cases) |c| {
            if (std.mem.eql(u8, nm, c.name)) {
                try std.testing.expectEqualStrings(c.label, prev.kindText());
                seen += 1;
            }
        }
        if (std.mem.eql(u8, nm, "link_to_note")) {
            try std.testing.expectEqual(walk.KIND_LINK, prev.kind);
            try std.testing.expect(!prev.is_dir);
            try std.testing.expectEqualStrings(
                theme.iconForEntry(&listing, ent, pal).name,
                theme.iconForPath(full, prev.kind, pal).name,
            );
            try std.testing.expectEqualStrings(
                theme.uiIconName("arrow.right.square"),
                theme.iconForPath(full, prev.kind, pal).name,
            );
        }
    }
    try std.testing.expectEqual(cases.len, seen);
}

const MockIconCtx = struct {
    calls: usize = 0,

    fn draw(raw: ?*anyopaque, gpa: std.mem.Allocator, _: []const u8, side: u32) ?[]u8 {
        const ctx: *MockIconCtx = @ptrCast(@alignCast(raw orelse return null));
        ctx.calls += 1;
        const bytes = gpa.alloc(u8, @as(usize, side) * side * 4) catch return null;
        @memset(bytes, 0x42);
        return bytes;
    }
};

test "media: IconCache caches hits, respects eviction budget, and frees all pixels on deinit" {
    const gpa = std.testing.allocator;
    var mock: MockIconCtx = .{};
    var cache: fs_media.IconCache = .{
        .gpa = gpa,
        .live_bytes_max = 10_000,
        .rasterizer = .{ .ctx = &mock, .icon = MockIconCtx.draw },
    };
    defer cache.deinit();

    const p1 = cache.lookup("/a/one.md", false, 16) orelse return error.MissingPixels;
    try std.testing.expectEqual(@as(u32, 32), p1.side);
    try std.testing.expectEqual(@as(usize, 1), mock.calls);

    const p2 = cache.lookup("/b/two.md", false, 16) orelse return error.MissingPixels;
    try std.testing.expectEqual(p1.key, p2.key);
    try std.testing.expectEqual(@as(usize, 1), mock.calls);

    _ = cache.lookup("/a/dir1", true, 16) orelse return error.MissingPixels;
    _ = cache.lookup("/a/dir2", true, 16) orelse return error.MissingPixels;
    try std.testing.expectEqual(@as(usize, 3), mock.calls);

    cache.beginFrame();
    try std.testing.expectEqual(@as(usize, 0), cache.live_bytes);

    _ = cache.lookup("/c/three.zig", false, 64) orelse return error.MissingPixels;
    try std.testing.expectEqual(@as(usize, 4), mock.calls);

    cache.beginFrame();
    _ = cache.lookup("/d/four.rs", false, 16) orelse return error.MissingPixels;
    try std.testing.expectEqual(@as(usize, 5), mock.calls);
}

test "media: IconCache defers misses past the frame budget and draws them on later frames" {
    const gpa = std.testing.allocator;
    var mock: MockIconCtx = .{};
    var cache: fs_media.IconCache = .{
        .gpa = gpa,
        .frame_budget_ns = 0,
        .rasterizer = .{ .ctx = &mock, .icon = MockIconCtx.draw },
    };
    defer cache.deinit();

    cache.beginFrame();
    _ = cache.lookup("/a/one.md", false, 16) orelse return error.MissingPixels;
    try std.testing.expect(cache.lookup("/a/dir1", true, 16) == null);
    try std.testing.expect(cache.lookup("/a/dir2", true, 16) == null);
    try std.testing.expectEqual(@as(usize, 1), mock.calls);
    try std.testing.expect(cache.deferred);
    _ = cache.lookup("/b/two.md", false, 16) orelse return error.MissingPixels;

    cache.beginFrame();
    try std.testing.expect(!cache.deferred);
    _ = cache.lookup("/a/dir1", true, 16) orelse return error.MissingPixels;
    try std.testing.expect(cache.lookup("/a/dir2", true, 16) == null);
    try std.testing.expectEqual(@as(usize, 2), mock.calls);

    cache.beginFrame();
    _ = cache.lookup("/a/dir2", true, 16) orelse return error.MissingPixels;
    try std.testing.expectEqual(@as(usize, 3), mock.calls);
    try std.testing.expect(!cache.deferred);
}

const MockPreviewCtx = struct {
    pdf_calls: usize = 0,
    img_calls: usize = 0,

    fn rasterizer(ctx: *MockPreviewCtx) fs_media.Rasterizer {
        return .{
            .ctx = ctx,
            .pdf_page = drawPdf,
            .image = drawImage,
        };
    }

    fn drawPdf(raw: ?*anyopaque, gpa: std.mem.Allocator, _: []const u8, index: u32, _: u32, _: u32) fs_media.PdfResult {
        const ctx: *MockPreviewCtx = @ptrCast(@alignCast(raw orelse return .{}));
        ctx.pdf_calls += 1;
        const w: u32 = 200;
        const h: u32 = 240;
        const bytes = gpa.alloc(u8, @as(usize, w) * h * 4) catch return .{};
        @memset(bytes, @intCast((index + 1) & 0xFF));
        return .{ .bitmap = .{ .bgra = bytes, .w = w, .h = h }, .pages = 3 };
    }

    fn drawImage(raw: ?*anyopaque, gpa: std.mem.Allocator, _: []const u8, _: u32, _: u32) ?fs_media.Bitmap {
        const ctx: *MockPreviewCtx = @ptrCast(@alignCast(raw orelse return null));
        ctx.img_calls += 1;
        const w: u32 = 100;
        const h: u32 = 100;
        const bytes = gpa.alloc(u8, @as(usize, w) * h * 4) catch return null;
        @memset(bytes, 0x77);
        return .{ .bgra = bytes, .w = w, .h = h };
    }
};

test "media: PreviewCache caches pages, invalidates on mtime change, skips folders named .pdf, and frees on deinit" {
    const gpa = std.testing.allocator;
    var mock: MockPreviewCtx = .{};
    var cache: fs_media.PreviewCache = .{
        .gpa = gpa,
        .rasterizer = mock.rasterizer(),
    };
    defer cache.deinit();

    try std.testing.expectEqual(@as(?fs_media.Shown, null), cache.show("/tmp/slides.pdf", walk.KIND_DIR, 100, 300, 400));
    try std.testing.expectEqual(@as(usize, 0), mock.pdf_calls);

    const s0 = cache.show("/tmp/slides.pdf", walk.KIND_FILE, 100, 300, 400) orelse return error.MissingPreview;
    try std.testing.expectEqual(@as(u32, 0), s0.page);
    try std.testing.expectEqual(@as(u32, 3), s0.pages);
    try std.testing.expectEqual(@as(u8, 1), s0.bgra[0]);
    try std.testing.expectEqual(@as(usize, 1), mock.pdf_calls);

    _ = cache.show("/tmp/slides.pdf", walk.KIND_FILE, 100, 300, 400) orelse return error.MissingPreview;
    try std.testing.expectEqual(@as(usize, 1), mock.pdf_calls);

    try std.testing.expect(cache.turn(1));
    const s1 = cache.show("/tmp/slides.pdf", walk.KIND_FILE, 100, 300, 400) orelse return error.MissingPreview;
    try std.testing.expectEqual(@as(u32, 1), s1.page);
    try std.testing.expectEqual(@as(u8, 2), s1.bgra[0]);
    try std.testing.expectEqual(@as(usize, 2), mock.pdf_calls);

    try std.testing.expect(cache.turn(10));
    const s2 = cache.show("/tmp/slides.pdf", walk.KIND_FILE, 100, 300, 400) orelse return error.MissingPreview;
    try std.testing.expectEqual(@as(u32, 2), s2.page);
    try std.testing.expectEqual(@as(u8, 3), s2.bgra[0]);
    try std.testing.expectEqual(@as(usize, 3), mock.pdf_calls);
    try std.testing.expect(!cache.turn(1));

    const s_mtime = cache.show("/tmp/slides.pdf", walk.KIND_FILE, 101, 300, 400) orelse return error.MissingPreview;
    try std.testing.expectEqual(@as(u32, 0), s_mtime.page);
    try std.testing.expectEqual(@as(u8, 1), s_mtime.bgra[0]);
    try std.testing.expectEqual(@as(usize, 4), mock.pdf_calls);
}

fn findInspectorPreviewRect(t: *ui.Tester) ?ui.Rect {
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .image => if (n.rect.x >= 900 and n.rect.w >= 40 and n.rect.h >= 40) return n.rect,
        else => {},
    };
    return null;
}

fn findInspectorIcon(t: *ui.Tester, name: []const u8) ?ui.Rect {
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .icon => |ic| if (n.rect.x >= 900 and std.mem.eql(u8, ic.name, name)) return n.rect,
        else => {},
    };
    return null;
}

test "media: inspector page buttons queue turn_preview_page via ui.Tester without mid-render mutation" {
    const gpa = std.testing.allocator;
    const tmp = try support.TempDir.create("/tmp/zigder-prevui");
    defer tmp.cleanup();
    const root = tmp.path();

    try support.sh("printf 'pdf' > '{s}/slides.pdf'", .{root});

    var engine = try support.initFixtureEngine(gpa, root, "ui.zidx");
    defer engine.deinit();

    var state = try app_mod.AppState.init(gpa, &engine, root, root);
    defer state.deinit();

    var mock: MockPreviewCtx = .{};
    state.media.setRasterizer(mock.rasterizer());

    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, view_mod.view), .{ .width = 1220, .height = 780 });
    defer t.deinit();
    t.settle(0.5);

    try t.clickText("slides.pdf");
    t.frame();
    try std.testing.expectEqual(@as(u32, 0), state.media.preview.page);

    const img_rect = findInspectorPreviewRect(&t) orelse return error.PreviewImageNotFound;
    t.moveTo(img_rect.x + img_rect.w / 2, img_rect.y + img_rect.h / 2);
    t.frame();

    const next_rect = findInspectorIcon(&t, "chevron.right") orelse return error.NextButtonNotFound;
    t.click(next_rect.x + next_rect.w / 2, next_rect.y + next_rect.h / 2);
    t.frame();
    try std.testing.expectEqual(@as(u32, 1), state.media.preview.page);

    const prev_rect = findInspectorIcon(&t, "chevron.left") orelse return error.PrevButtonNotFound;
    t.click(prev_rect.x + prev_rect.w / 2, prev_rect.y + prev_rect.h / 2);
    t.frame();
    try std.testing.expectEqual(@as(u32, 0), state.media.preview.page);

    try std.testing.expect(t.shortcut(.{ .key = 'n', .cmd = true, .shift = true }));
    t.frame();
    try std.testing.expectEqual(session.OverlayKind.new_folder, state.overlay.kind());
    try std.testing.expect(!commands.dispatch(&state, .{ .turn_preview_page = 1 }));
    try std.testing.expectEqual(@as(u32, 0), state.media.preview.page);
}
