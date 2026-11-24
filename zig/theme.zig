const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const fs_entry = @import("fs_entry.zig");
const volumes = @import("volumes.zig");
const walk = @import("walk.zig");

pub const Palette = struct {
    dark: bool,
    bg: ui.Color,
    surface: ui.Color,
    chrome: ui.Color,
    row_alt: ui.Color,
    row_hover: ui.Color,
    row_sel: ui.Color,
    row_sel_muted: ui.Color,
    border: ui.Color,
    divider: ui.Color,
    text: ui.Color,
    muted: ui.Color,
    subtle: ui.Color,
    accent: ui.Color,
    accent_text: ui.Color,
    folder: ui.Color,
    code: ui.Color,
    badge_bg: ui.Color,
    code_bg: ui.Color,
    danger: ui.Color,
    success: ui.Color,

    pub fn from(c: *const ui.Context) Palette {
        if (c.theme.dark) {
            return .{
                .dark = true,
                .bg = ui.Color.hex(0x16171A),
                .surface = ui.Color.hex(0x1E2024),
                .chrome = ui.Color.hex(0x23252A),
                .row_alt = ui.Color.hex(0x1B1C20),
                .row_hover = ui.Color.hex(0x292C33),
                .row_sel = ui.Color.hex(0x1957B8),
                .row_sel_muted = ui.Color.hex(0x2D3139),
                .border = ui.Color.hex(0x363941),
                .divider = ui.Color.hex(0x2A2D34),
                .text = ui.Color.hex(0xF3F4F6),
                .muted = ui.Color.hex(0x9BA1AB),
                .subtle = ui.Color.hex(0x6E7480),
                .accent = ui.Color.hex(0x2E8BFF),
                .accent_text = ui.Color.white,
                .folder = ui.Color.hex(0x47A3FF),
                .code = ui.Color.hex(0x64D2FF),
                .badge_bg = ui.Color.hex(0x2B2F37),
                .code_bg = ui.Color.hex(0x121316),
                .danger = ui.Color.hex(0xFF453A),
                .success = ui.Color.hex(0x30D158),
            };
        }
        return .{
            .dark = false,
            .bg = ui.Color.hex(0xFFFFFF),
            .surface = ui.Color.hex(0xF6F7F9),
            .chrome = ui.Color.hex(0xF2F3F6),
            .row_alt = ui.Color.hex(0xF9FAFB),
            .row_hover = ui.Color.hex(0xECEEF3),
            .row_sel = ui.Color.hex(0x0A84FF),
            .row_sel_muted = ui.Color.hex(0xE2E5EC),
            .border = ui.Color.hex(0xD8DCE3),
            .divider = ui.Color.hex(0xE6E9EF),
            .text = ui.Color.hex(0x1C1E22),
            .muted = ui.Color.hex(0x5F6570),
            .subtle = ui.Color.hex(0x888E99),
            .accent = ui.Color.hex(0x0A84FF),
            .accent_text = ui.Color.white,
            .folder = ui.Color.hex(0x2B95FF),
            .code = ui.Color.hex(0x0070C9),
            .badge_bg = ui.Color.hex(0xE9ECF2),
            .code_bg = ui.Color.hex(0xF4F5F8),
            .danger = ui.Color.hex(0xFF3B30),
            .success = ui.Color.hex(0x28CD41),
        };
    }
};

pub const IconSpec = struct {
    name: []const u8,
    color: ui.Color,
};

pub fn tagColor(bit: u3) ui.Color {
    const idx: usize = @min(@as(usize, bit), volumes.finder_tags.len - 1);
    return ui.Color.hex(@as(u24, @truncate(volumes.finder_tags[idx].rgb)));
}

pub fn uiIconName(raw: []const u8) []const u8 {
    if (!ui.portable) return raw;
    if (ui.icons.find(raw) != null) return raw;
    const map = [_]struct { []const u8, []const u8 }{
        .{ "house.fill", "star.fill" },
        .{ "menubar.dock.rectangle", "desktopcomputer" },
        .{ "doc.fill", "doc.text" },
        .{ "arrow.down.circle.fill", "arrow.right.square" },
        .{ "square.grid.2x2.fill", "square.grid.2x2" },
        .{ "trash.fill", "trash" },
        .{ "icloud.fill", "globe" },
        .{ "internaldrive.fill", "internaldrive" },
        .{ "externaldrive.fill", "internaldrive" },
        .{ "circle.fill", "circle" },
        .{ "list.bullet.indent", "list.bullet" },
        .{ "photo.on.rectangle.angled", "photo" },
        .{ "folder.fill", "folder" },
    };
    for (map) |m| {
        if (std.mem.eql(u8, raw, m[0])) return m[1];
    }
    return "circle";
}

pub fn iconForEntry(listing: *const fs_entry.FolderListing, e: fs_entry.DirEntry, pal: Palette) IconSpec {
    if ((e.kind & 3) == walk.KIND_LINK) return .{ .name = uiIconName("arrow.right.square"), .color = pal.muted };
    if (e.isFolderRow()) return .{ .name = uiIconName("folder"), .color = pal.folder };
    if ((e.flags & fs_entry.FLAG_APP) != 0) return .{ .name = uiIconName("app.badge"), .color = pal.accent };
    if (e.isPackage()) return .{ .name = uiIconName("cube"), .color = pal.muted };
    const ext = listing.extOf(e);
    return iconForExt(ext, pal);
}

pub fn iconForPath(path: []const u8, kind: u8, pal: Palette) IconSpec {
    const base_k = kind & 3;
    if (base_k == walk.KIND_LINK) return .{ .name = uiIconName("arrow.right.square"), .color = pal.muted };
    const nm = std.fs.path.basename(path);
    if (base_k == walk.KIND_DIR) {
        if (nm.len > 4 and std.ascii.eqlIgnoreCase(nm[nm.len - 4 ..], ".app")) {
            return .{ .name = uiIconName("app.badge"), .color = pal.accent };
        }
        if (fs_entry.isPackageName(nm)) return .{ .name = uiIconName("cube"), .color = pal.muted };
        return .{ .name = uiIconName("folder"), .color = pal.folder };
    }
    if (std.mem.lastIndexOfScalar(u8, nm, '.')) |dot| {
        if (dot + 1 < nm.len) return iconForExt(nm[dot + 1 ..], pal);
    }
    return .{ .name = uiIconName("doc"), .color = pal.muted };
}

fn iconForExt(ext: []const u8, pal: Palette) IconSpec {
    if (extIn(ext, &.{ "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "tiff", "bmp" })) {
        return .{ .name = uiIconName("photo"), .color = ui.Color.hex(0xAF52DE) };
    }
    if (extIn(ext, &.{ "mp3", "m4a", "wav", "flac", "aac", "ogg", "opus" })) {
        return .{ .name = uiIconName("music.note"), .color = ui.Color.hex(0xFF2D55) };
    }
    if (extIn(ext, &.{ "zig", "rs", "c", "h", "cpp", "hpp", "swift", "go", "py", "ts", "tsx", "js", "jsx", "json", "toml", "yaml", "yml", "nix" })) {
        return .{ .name = uiIconName("chevron.left.forwardslash.chevron.right"), .color = pal.code };
    }
    if (extIn(ext, &.{ "sh", "zsh", "bash" })) {
        return .{ .name = uiIconName("terminal"), .color = pal.success };
    }
    if (extIn(ext, &.{ "md", "txt", "rtf", "pdf", "doc", "docx" })) {
        return .{ .name = uiIconName("doc.text"), .color = pal.muted };
    }
    if (extIn(ext, &.{ "zip", "tar", "gz", "tgz", "dmg", "7z", "xz", "zst" })) {
        return .{ .name = uiIconName("cube"), .color = ui.Color.hex(0xFF9500) };
    }
    return .{ .name = uiIconName("doc"), .color = pal.muted };
}

fn extIn(ext: []const u8, list: []const []const u8) bool {
    for (list) |item| {
        if (std.ascii.eqlIgnoreCase(ext, item)) return true;
    }
    return false;
}

pub fn kindLabel(listing: *const fs_entry.FolderListing, e: fs_entry.DirEntry) []const u8 {
    if ((e.kind & 3) == walk.KIND_LINK) return "Alias";
    if ((e.flags & fs_entry.FLAG_APP) != 0) return "Application";
    if (e.isPackage()) return "Package";
    if (e.isFolderRow()) return "Folder";
    const ext = listing.extOf(e);
    if (ext.len == 0) return "Document";
    if (std.ascii.eqlIgnoreCase(ext, "zig")) return "Zig Source";
    if (std.ascii.eqlIgnoreCase(ext, "rs")) return "Rust Source";
    if (std.ascii.eqlIgnoreCase(ext, "md")) return "Markdown";
    if (std.ascii.eqlIgnoreCase(ext, "json")) return "JSON";
    if (std.ascii.eqlIgnoreCase(ext, "toml")) return "TOML";
    if (extIn(ext, &.{ "png", "jpg", "jpeg", "gif", "webp", "svg" })) return "Image";
    if (extIn(ext, &.{ "pdf", "txt", "doc", "docx" })) return "Text / Doc";
    return "Document";
}

pub fn fmtBytesBuf(buf: []u8, bytes: u64) []const u8 {
    if (bytes < 1000) return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "?";
    const f: f64 = @floatFromInt(bytes);
    if (bytes < 1_000_000) return std.fmt.bufPrint(buf, "{d:.1} KB", .{f / 1000.0}) catch "?";
    if (bytes < 1_000_000_000) return std.fmt.bufPrint(buf, "{d:.1} MB", .{f / 1_000_000.0}) catch "?";
    return std.fmt.bufPrint(buf, "{d:.2} GB", .{f / 1_000_000_000.0}) catch "?";
}

pub fn fmtBytes(c: *ui.Context, bytes: u64) []const u8 {
    var buf: [32]u8 = undefined;
    return c.alloc().dupe(u8, fmtBytesBuf(&buf, bytes)) catch "…";
}

pub fn fmtMtimeBuf(buf: []u8, mtime: u32) []const u8 {
    if (mtime == 0) return "--";
    const secs: i64 = @intCast(mtime);
    const days = @divFloor(secs, 86_400);
    const rem = @mod(secs, 86_400);
    const hour: u32 = @intCast(@divFloor(rem, 3600));
    const min: u32 = @intCast(@divFloor(@mod(rem, 3600), 60));

    const z = days + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe: u64 = @intCast(z - era * 146097);
    const yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    var y: i64 = @as(i64, @intCast(yoe)) + era * 400;
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp = (5 * doy + 2) / 153;
    const d: u32 = @intCast(doy - (153 * mp + 2) / 5 + 1);
    const m: u32 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    if (m <= 2) y += 1;
    const uy: u32 = @intCast(@max(y, 0));

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{ uy, m, d, hour, min }) catch "--";
}

pub fn fmtMtime(c: *ui.Context, mtime: u32) []const u8 {
    var buf: [32]u8 = undefined;
    return c.alloc().dupe(u8, fmtMtimeBuf(&buf, mtime)) catch "--";
}

pub fn describeNode(c: *ui.Context, idx: u32, role: ui.A11yRole, lbl: []const u8, val: []const u8, selected: bool, enabled: bool) void {
    ui.access.describe(c, idx, .{
        .role = role,
        .label = lbl,
        .value = val,
        .selected = selected,
        .enabled = enabled,
    });
}
