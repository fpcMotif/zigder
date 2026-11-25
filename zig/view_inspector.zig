const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_mod = @import("app.zig");
const AppState = app_mod.AppState;
const theme = @import("theme.zig");
const Palette = theme.Palette;
const volumes = @import("volumes.zig");
const file_icons = @import("file_icons.zig");
const file_preview = @import("file_preview.zig");

const pane_w: f32 = 320;
const content_w: f32 = pane_w - 2 * theme.metric.pane_inset;
const preview_max_h: f32 = 360;
const page_button: f32 = 28;

pub fn render(s: *AppState, c: *ui.Context, pal: Palette) void {
    const pane = ui.div(c).column().w(pane_w).hFull().p(theme.metric.pane_inset).gap(12).bg(pal.surface).border(pal.divider).borderW(0.5).scrollY().scrollbar(theme.scrollbar(pal));
    defer pane.end();

    if (!s.inspector.valid) {
        ui.text(c, "No selection", .{ .size = 13, .color = pal.muted });
        return;
    }

    const full_path = s.inspector_path.items;
    const base = if (std.mem.eql(u8, full_path, "/")) "Macintosh HD" else std.fs.path.basename(full_path);

    preview(s, c, pal, full_path);

    {
        const head = ui.div(c).column().wFull().gap(2);
        defer head.end();
        ui.text(c, base, .{ .size = theme.size.title, .weight = .semibold, .color = pal.text, .truncate = .ellipsis });
        ui.textf(c, .{ .size = theme.size.body, .color = pal.muted }, "{s} - {s}", .{ s.inspector.kindText(), theme.fmtBytes(c, s.inspector.size) });
    }

    {
        const meta = ui.div(c).column().wFull();
        defer meta.end();
        ui.text(c, "Information", .{ .size = theme.size.body, .weight = .semibold, .color = pal.text });
        metaRow(c, pal, "Created", theme.fmtLongDate(c, s.inspector.created), false);
        metaRow(c, pal, "Modified", theme.fmtLongDate(c, s.inspector.mtime), true);
        if (s.inspector.last_opened != 0) {
            metaRow(c, pal, "Last opened", theme.fmtLongDate(c, s.inspector.last_opened), true);
        }
        if (s.inspector.image_w > 0 and s.inspector.image_h > 0) {
            metaRow(c, pal, "Dimensions", c.print("{d}×{d}", .{ s.inspector.image_w, s.inspector.image_h }), true);
        }
    }

    {
        const tag_sec = ui.div(c).column().wFull().gap(6);
        defer tag_sec.end();
        ui.text(c, "Tags", .{ .size = theme.size.body, .weight = .semibold, .color = pal.text });
        const row = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer row.end();
        for (volumes.finder_tags) |t| {
            ui.key(c, c.print("itag-{d}", .{t.bit}));
            const on = (s.inspector.tag_mask & (@as(u8, 1) << t.bit)) != 0;
            const dot_col = theme.tagColor(t.bit);
            const btn = ui.div(c).w(20).h(20).roundedFull().circular().center().bg(if (on) dot_col else dot_col.alpha(0)).control();
            const it = btn.interaction();
            theme.describeNode(c, btn.index, .checkbox, t.name, "", on, true);
            if (on) {
                ui.icon(c, "checkmark", .{ .size = 10, .color = ui.Color.white });
            } else {
                ui.div(c).w(12).h(12).roundedFull().circular().bg(dot_col).end();
            }
            btn.end();
            if (it.clicked) s.actionToggleTag(t.bit);
        }
    }
}

fn preview(s: *AppState, c: *ui.Context, pal: Palette, full_path: []const u8) void {
    const points_to_pixels: f32 = 2;
    if (file_preview.show(full_path, s.inspector.mtime, @intFromFloat(content_w * points_to_pixels), @intFromFloat(preview_max_h * points_to_pixels))) |shot| {
        const w = @as(f32, @floatFromInt(shot.w)) / points_to_pixels;
        const h = @as(f32, @floatFromInt(shot.h)) / points_to_pixels;
        const frame = ui.div(c).row().wFull().h(h).justifyCenter().control();
        const it = frame.interaction();
        defer frame.end();
        _ = ui.image(c, .{
            .key = c.print("preview-{x}-{d}", .{ shot.key, shot.page }),
            .source = .{ .pixels = .{ .bgra = shot.bgra, .width = shot.w, .height = shot.h } },
            .box = .{ .w = w, .h = h },
            .radius = 3,
        });
        if (shot.pages > 1 and it.hovered) {
            const y = (h - page_button) / 2;
            if (pageButton(c, "chevron.left", "Previous Page", 6, y, shot.page > 0)) file_preview.turn(-1);
            if (pageButton(c, "chevron.right", "Next Page", content_w - page_button - 6, y, shot.page + 1 < shot.pages)) file_preview.turn(1);
        }
        return;
    }

    if (s.inspector.is_text and s.inspector.snippetText().len > 0) {
        const sn = s.inspector.snippetText();
        const code_box = ui.div(c).wFull().p(8).rounded(6).bg(pal.code_bg).border(pal.border).borderW(0.5).clip();
        ui.text(c, sn[0..@min(sn.len, 900)], .{ .size = 11, .mono = true, .color = pal.text, .wrap = true, .max_lines = 14 });
        code_box.end();
        return;
    }

    const kind_byte: u8 = if (s.inspector.is_dir) 1 else 0;
    const frame = ui.div(c).row().wFull().py(12).justifyCenter();
    defer frame.end();
    file_icons.path(c, full_path, kind_byte, 128, theme.iconForPath(full_path, kind_byte, pal), null);
}

fn pageButton(c: *ui.Context, icon: []const u8, label: []const u8, x: f32, y: f32, enabled: bool) bool {
    ui.key(c, label);
    const btn = ui.div(c).absolute().offset(x, y).w(page_button).h(page_button).roundedFull().circular().center().bg(ui.Color.black.alpha(if (enabled) 0.5 else 0.2)).control();
    const it = btn.interaction();
    theme.describeNode(c, btn.index, .button, label, "", false, enabled);
    ui.icon(c, icon, .{ .size = 12, .weight = .semibold, .color = ui.Color.white });
    btn.end();
    return enabled and it.clicked;
}

fn metaRow(c: *ui.Context, pal: Palette, key: []const u8, val: []const u8, divided: bool) void {
    if (divided) ui.div(c).wFull().h(0.5).bg(pal.divider).end();
    const r = ui.div(c).row().wFull().h(24).justifyBetween().itemsCenter().gap(8);
    defer r.end();
    ui.text(c, key, .{ .size = theme.size.caption, .color = pal.muted });
    ui.text(c, val, .{ .size = theme.size.caption, .color = pal.text, .tabular = true, .truncate = .ellipsis });
}
