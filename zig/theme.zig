const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const fs_entry = @import("fs_entry.zig");
const volumes = @import("volumes.zig");
const walk = @import("walk.zig");

const SystemAccent = struct { accent: ui.Color, selection: ui.Color };
var system_accent: ?SystemAccent = null;

fn systemColor(comptime selector: [:0]const u8) ?ui.Color {
    if (comptime ui.portable) return null;
    const objc = nanoui.objc;
    const pool = objc.Pool.push();
    defer pool.pop();
    const raw = objc.msg(?objc.Object, objc.class("NSColor"), selector, .{}) orelse return null;
    const space = objc.msg(?objc.Object, objc.class("NSColorSpace"), "sRGBColorSpace", .{}) orelse return null;
    const rgb = objc.msg(?objc.Object, raw, "colorUsingColorSpace:", .{space}) orelse return null;
    return .{
        .r = @floatCast(objc.msg(f64, rgb, "redComponent", .{})),
        .g = @floatCast(objc.msg(f64, rgb, "greenComponent", .{})),
        .b = @floatCast(objc.msg(f64, rgb, "blueComponent", .{})),
    };
}

fn systemAccent() SystemAccent {
    if (system_accent) |cached| return cached;
    const found: SystemAccent = .{
        .accent = systemColor("controlAccentColor") orelse ui.Color.hex(0x0088FF),
        .selection = systemColor("selectedContentBackgroundColor") orelse ui.Color.hex(0x0063E1),
    };
    system_accent = found;
    return found;
}

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
        const sys = systemAccent();
        if (c.theme.dark) {
            return .{
                .dark = true,
                .bg = ui.Color.hex(0x1E1E1E),
                .surface = ui.Color.hex(0x262626),
                .chrome = ui.Color.hex(0x2A2A2A),
                .row_alt = ui.Color.hex(0x292929),
                .row_hover = ui.Color.hex(0x303030),
                .row_sel = sys.selection.mix(ui.Color.black, 0.07),
                .row_sel_muted = ui.Color.hex(0x464646),
                .border = ui.Color.hex(0x3D3D3D),
                .divider = ui.Color.hex(0x393939),
                .text = ui.Color.hex(0xDDDDDD),
                .muted = ui.Color.hex(0x999999),
                .subtle = ui.Color.hex(0x6E6E6E),
                .accent = sys.accent,
                .accent_text = ui.Color.white,
                .folder = sys.accent,
                .code = ui.Color.hex(0x64D2FF),
                .badge_bg = ui.Color.hex(0x363636),
                .code_bg = ui.Color.hex(0x171717),
                .danger = ui.Color.hex(0xFF453A),
                .success = ui.Color.hex(0x30D158),
            };
        }
        return .{
            .dark = false,
            .bg = ui.Color.hex(0xFFFFFF),
            .surface = ui.Color.hex(0xF5F5F5),
            .chrome = ui.Color.hex(0xF6F6F6),
            .row_alt = ui.Color.hex(0xF4F5F5),
            .row_hover = ui.Color.hex(0xECECEC),
            .row_sel = sys.selection,
            .row_sel_muted = ui.Color.hex(0xDCDCDC),
            .border = ui.Color.hex(0xD9D9D9),
            .divider = ui.Color.hex(0xE5E5E5),
            .text = ui.Color.hex(0x262626),
            .muted = ui.Color.hex(0x808080),
            .subtle = ui.Color.hex(0x8E8E8E),
            .accent = sys.accent,
            .accent_text = ui.Color.white,
            .folder = sys.accent,
            .code = ui.Color.hex(0x0070C9),
            .badge_bg = ui.Color.hex(0xE8E8E8),
            .code_bg = ui.Color.hex(0xF5F5F5),
            .danger = ui.Color.hex(0xFF3B30),
            .success = ui.Color.hex(0x28CD41),
        };
    }
};

pub const size = struct {
    pub const title: f32 = 15;
    pub const body: f32 = 13;
    pub const callout: f32 = 12;
    pub const caption: f32 = 11;
};

pub const metric = struct {
    pub const toolbar_h: f32 = 52;
    pub const row_h: f32 = 20;
    pub const column_row_h: f32 = 24;
    pub const bar_h: f32 = 28;
    pub const row_radius: f32 = 8;
    pub const pane_inset: f32 = 10;
    pub const date_col_w: f32 = 181;
    pub const size_col_w: f32 = 97;
    pub const kind_col_w: f32 = 115;
};

pub const IconSpec = struct {
    name: []const u8,
    color: ui.Color,
};

pub fn scrollbar(pal: Palette) @FieldType(ui.Style, "scrollbar") {
    return .{ .overlay = pal.text.alpha(0.5) };
}

pub fn listScrollbar(c: *ui.Context, pal: Palette) void {
    c.node(c.stack.items[c.stack.items.len - 1]).style.scrollbar = scrollbar(pal);
}

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
        .{ "rectangle.split.3x1", "rectangle.split.2x1" },
        .{ "squares.below.rectangle", "photo" },
    };
    for (map) |m| {
        if (std.mem.eql(u8, raw, m[0])) return m[1];
    }
    return "circle";
}

pub fn iconForEntry(listing: *const fs_entry.FolderListing, e: fs_entry.DirEntry, pal: Palette) IconSpec {
    if ((e.kind & 3) == walk.KIND_LINK) return .{ .name = uiIconName("arrow.right.square"), .color = pal.muted };
    if (e.isFolderRow()) return .{ .name = uiIconName("folder.fill"), .color = pal.folder };
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
        return .{ .name = uiIconName("folder.fill"), .color = pal.folder };
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
    if (std.ascii.eqlIgnoreCase(ext, "pdf")) return "PDF Document";
    if (std.ascii.eqlIgnoreCase(ext, "txt")) return "Plain Text";
    if (extIn(ext, &.{ "doc", "docx" })) return "Word Document";
    return "Document";
}

pub fn fmtBytesBuf(buf: []u8, bytes: u64) []const u8 {
    if (bytes == 0) return "Zero bytes";
    if (bytes == 1) return "1 byte";
    if (bytes < 1000) return std.fmt.bufPrint(buf, "{d} bytes", .{bytes}) catch "?";
    const f: f64 = @floatFromInt(bytes);
    if (bytes < 999_500) return std.fmt.bufPrint(buf, "{d:.0} KB", .{f / 1000.0}) catch "?";
    if (bytes < 1_000_000_000) return std.fmt.bufPrint(buf, "{d:.1} MB", .{f / 1_000_000.0}) catch "?";
    if (bytes < 100_000_000_000) return std.fmt.bufPrint(buf, "{d:.2} GB", .{f / 1_000_000_000.0}) catch "?";
    return std.fmt.bufPrint(buf, "{d:.1} GB", .{f / 1_000_000_000.0}) catch "?";
}

pub fn fmtCountBuf(buf: *[26]u8, n: u64) []const u8 {
    var digits_buf: [20]u8 = undefined;
    const digits = std.fmt.bufPrint(&digits_buf, "{d}", .{n}) catch unreachable;
    var len: usize = 0;
    for (digits, 0..) |digit, i| {
        if (i != 0 and (digits.len - i) % 3 == 0) {
            buf[len] = ',';
            len += 1;
        }
        buf[len] = digit;
        len += 1;
    }
    return buf[0..len];
}

pub fn fmtCount(c: *ui.Context, n: u64) []const u8 {
    var buf: [26]u8 = undefined;
    return c.alloc().dupe(u8, fmtCountBuf(&buf, n)) catch "…";
}

pub fn fmtElapsedBuf(buf: []u8, micros: u64) []const u8 {
    if (micros < 1000) return std.fmt.bufPrint(buf, "{d} µs", .{micros}) catch "?";
    return std.fmt.bufPrint(buf, "{d:.1} ms", .{@as(f64, @floatFromInt(micros)) / 1000.0}) catch "?";
}

pub fn fmtElapsed(c: *ui.Context, micros: u64) []const u8 {
    var buf: [32]u8 = undefined;
    return c.alloc().dupe(u8, fmtElapsedBuf(&buf, micros)) catch "…";
}

pub const LocalDate = struct { year: u32, month: u32, day: u32, hour: u32, minute: u32 };

const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

pub const Clock = enum { h12, h24 };

fn fmtClockBuf(buf: []u8, d: LocalDate, clock: Clock) ![]const u8 {
    const hour12: u32 = if (d.hour % 12 == 0) 12 else d.hour % 12;
    const half: []const u8 = if (d.hour < 12) "AM" else "PM";
    return switch (clock) {
        .h12 => std.fmt.bufPrint(buf, "{d}:{d:0>2} {s}", .{ hour12, d.minute, half }),
        .h24 => std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ d.hour, d.minute }),
    };
}

pub fn fmtDateBuf(buf: []u8, d: LocalDate, days_ago: i64, clock: Clock) []const u8 {
    var time_buf: [16]u8 = undefined;
    const at = fmtClockBuf(&time_buf, d, clock) catch return "--";
    if (days_ago == 0) return std.fmt.bufPrint(buf, "Today at {s}", .{at}) catch "--";
    if (days_ago == 1) return std.fmt.bufPrint(buf, "Yesterday at {s}", .{at}) catch "--";
    const month = month_names[@min(d.month -| 1, 11)];
    return std.fmt.bufPrint(buf, "{s} {d}, {d} at {s}", .{ month, d.day, d.year, at }) catch "--";
}

const long_months = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
const weekdays = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };

pub fn fmtLongDateBuf(buf: []u8, d: LocalDate, weekday: u32, clock: Clock) []const u8 {
    var time_buf: [16]u8 = undefined;
    const at = fmtClockBuf(&time_buf, d, clock) catch return "--";
    return std.fmt.bufPrint(buf, "{s}, {s} {d}, {d} at {s}", .{ weekdays[@min(weekday, 6)], long_months[@min(d.month -| 1, 11)], d.day, d.year, at }) catch "--";
}

pub fn fmtLongDate(c: *ui.Context, unix: u32) []const u8 {
    if (unix == 0) return "--";
    const secs: c_long = @intCast(unix);
    var tm: Tm = undefined;
    if (localtime_r(&secs, &tm) == null) return "--";
    var buf: [64]u8 = undefined;
    return c.alloc().dupe(u8, fmtLongDateBuf(&buf, .{
        .year = @intCast(@max(tm.year + 1900, 0)),
        .month = @intCast(tm.mon + 1),
        .day = @intCast(tm.mday),
        .hour = @intCast(tm.hour),
        .minute = @intCast(tm.min),
    }, @intCast(tm.wday), systemClock())) catch "--";
}

var system_clock: ?Clock = null;

fn systemClock() Clock {
    if (system_clock) |cached| return cached;
    const found: Clock = blk: {
        if (comptime ui.portable) break :blk .h12;
        const objc = nanoui.objc;
        const pool = objc.Pool.push();
        defer pool.pop();
        const locale = objc.msg(?objc.Object, objc.class("NSLocale"), "currentLocale", .{}) orelse break :blk .h12;
        const pattern = objc.msg(?objc.Object, objc.class("NSDateFormatter"), "dateFormatFromTemplate:options:locale:", .{ objc.nsString("j"), @as(usize, 0), locale });
        break :blk if (std.mem.indexOfScalar(u8, objc.fromNSString(pattern), 'a') != null) .h12 else .h24;
    };
    system_clock = found;
    return found;
}

const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};
extern "c" fn localtime_r(t: *const c_long, out: *Tm) ?*Tm;
extern "c" fn time(t: ?*c_long) c_long;

fn localDay(secs: c_long, tm: Tm) i64 {
    return @divFloor(@as(i64, secs) + tm.gmtoff, 86_400);
}

pub fn fmtBytes(c: *ui.Context, bytes: u64) []const u8 {
    var buf: [32]u8 = undefined;
    return c.alloc().dupe(u8, fmtBytesBuf(&buf, bytes)) catch "…";
}

pub fn fmtMtimeBuf(buf: []u8, mtime: u32) []const u8 {
    if (mtime == 0) return "--";
    const secs: c_long = @intCast(mtime);
    const now: c_long = time(null);
    var tm: Tm = undefined;
    var now_tm: Tm = undefined;
    if (localtime_r(&secs, &tm) == null or localtime_r(&now, &now_tm) == null) return "--";
    return fmtDateBuf(buf, .{
        .year = @intCast(@max(tm.year + 1900, 0)),
        .month = @intCast(tm.mon + 1),
        .day = @intCast(tm.mday),
        .hour = @intCast(tm.hour),
        .minute = @intCast(tm.min),
    }, localDay(now, now_tm) - localDay(secs, tm), systemClock());
}

pub fn fmtMtime(c: *ui.Context, mtime: u32) []const u8 {
    var buf: [48]u8 = undefined;
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
