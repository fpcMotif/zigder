const nanoui = @import("nanoui");
const ui = nanoui.ui;
const fs_entry = @import("../fs/entry.zig");
const fs_kind = @import("../fs/kind.zig");
const fs_media = @import("../fs/media.zig");
const index_read = @import("../index/read.zig");
const theme = @import("theme.zig");

pub fn entry(c: *ui.Context, icons: *fs_media.IconCache, listing: *const fs_entry.FolderListing, e: fs_entry.DirEntry, pt: f32, spec: theme.IconSpec, tint: ?ui.Color) void {
    var buf: [2048]u8 = undefined;
    if (index_read.joinBuf(&buf, listing.path, listing.nameOf(e))) |full| {
        if (show(c, icons, full, fs_kind.isContainerKind(e.kind), pt)) return;
    }
    symbol(c, pt, spec, tint);
}

pub fn path(c: *ui.Context, icons: *fs_media.IconCache, full: []const u8, kind: u8, pt: f32, spec: theme.IconSpec, tint: ?ui.Color) void {
    if (show(c, icons, full, fs_kind.isContainerKind(kind), pt)) return;
    symbol(c, pt, spec, tint);
}

fn symbol(c: *ui.Context, pt: f32, spec: theme.IconSpec, tint: ?ui.Color) void {
    const small = pt <= fs_media.small_max_pt;
    ui.icon(c, spec.name, .{ .size = if (small) pt - 1 else pt, .color = tint orelse spec.color, .frame = if (small) pt + 2 else null });
}

fn show(c: *ui.Context, icons: *fs_media.IconCache, full: []const u8, container: bool, pt: f32) bool {
    const px = icons.lookup(full, container, pt) orelse return false;
    return ui.image(c, .{
        .key = c.print("file-icon-{x}", .{px.key}),
        .source = .{ .pixels = .{ .bgra = px.bgra, .width = px.side, .height = px.side } },
        .box = .{ .w = pt, .h = pt },
        .radius = 0,
    });
}
