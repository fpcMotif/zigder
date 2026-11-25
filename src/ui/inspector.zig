const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_mod = @import("../app/app.zig");
const AppState = app_mod.AppState;
const commands = @import("../app/commands.zig");
const theme = @import("theme.zig");
const Palette = theme.Palette;
const volumes = @import("../fs/volumes.zig");
const fs_media = @import("../fs/media.zig");
const file_icons = @import("file_icons.zig");

const pane_w: f32 = 318;
const pane_pad: f32 = 11;
const content_w: f32 = pane_w - 2 * pane_pad;
const preview_max_h: f32 = 340;

const TagPicker = struct {
    open: bool = false,
    path_hash: u64 = 0,
};

pub fn render(s: *const AppState, c: *ui.Context, pal: Palette, media: *fs_media.MediaCache, q: *commands.Queue) void {
    const pane = ui.div(c).column().w(pane_w).hFull().p(pane_pad).gap(14).bg(pal.surface).scrollY().scrollbar(theme.scrollbar(pal));
    defer pane.end();

    if (!s.inspector.valid) {
        const empty = ui.div(c).column().sizeFull().center();
        defer empty.end();
        ui.text(c, "No Selection", .{ .size = 13, .color = pal.subtle });
        return;
    }

    const full_path = s.inspector_path.items;
    const base = theme.displayName(full_path);

    if (s.view_mode == .gallery) {
        const head = ui.div(c).row().wFull().pt(4).gap(10).itemsCenter();
        defer head.end();
        const kind_byte = s.inspector.kind;
        file_icons.path(c, &media.icons, full_path, kind_byte, 48, theme.iconForPath(full_path, kind_byte, pal), null);
        const titles = ui.div(c).column().grow().gap(2).clip();
        defer titles.end();
        ui.text(c, base, .{ .size = theme.size.title, .weight = .semibold, .color = pal.text, .truncate = .ellipsis });
        renderSubtitle(s, c, pal);
    } else {
        preview(s, c, pal, full_path, media, q);
        const head = ui.div(c).column().wFull().gap(2);
        defer head.end();
        ui.text(c, base, .{ .size = theme.size.title, .weight = .semibold, .color = pal.text, .truncate = .ellipsis });
        renderSubtitle(s, c, pal);
    }

    {
        const meta = ui.div(c).column().wFull().gap(2);
        defer meta.end();
        ui.text(c, "Information", .{ .size = theme.size.body, .weight = .semibold, .color = pal.text });
        const rows = ui.div(c).column().wFull().pt(4);
        defer rows.end();
        metaRow(c, pal, "Created", theme.fmtLongDate(c, s.inspector.created), false);
        metaRow(c, pal, "Modified", theme.fmtLongDate(c, s.inspector.mtime), true);
        if (s.inspector.last_opened != 0) {
            metaRow(c, pal, "Last opened", theme.fmtLongDate(c, s.inspector.last_opened), true);
        }
        if (s.inspector.image_w > 0 and s.inspector.image_h > 0) {
            metaRow(c, pal, "Dimensions", c.print("{d} × {d}", .{ s.inspector.image_w, s.inspector.image_h }), true);
        }
    }

    renderTags(s, c, pal, full_path, q);
}

fn renderSubtitle(s: *const AppState, c: *ui.Context, pal: Palette) void {
    if (s.inspector.is_dir and s.inspector.size == 0) {
        ui.text(c, s.inspector.kindText(), .{ .size = theme.size.body, .color = pal.muted });
    } else {
        ui.textf(c, .{ .size = theme.size.body, .color = pal.muted, .tabular = true }, "{s} - {s}", .{
            s.inspector.kindText(),
            theme.fmtBytes(c, s.inspector.size),
        });
    }
}

fn renderTags(s: *const AppState, c: *ui.Context, pal: Palette, full_path: []const u8, q: *commands.Queue) void {
    const picker = c.state(TagPicker, "insp-tag-picker");
    const h = std.hash.Wyhash.hash(0, full_path);
    if (picker.path_hash != h) {
        picker.path_hash = h;
        picker.open = false;
    }

    const tag_sec = ui.div(c).column().wFull().gap(6);
    defer tag_sec.end();

    {
        const hdr = ui.div(c).row().wFull().justifyBetween().itemsCenter();
        defer hdr.end();
        ui.text(c, "Tags", .{ .size = theme.size.body, .weight = .semibold, .color = pal.text });
        if (s.inspector.tag_mask != 0 or picker.open) {
            ui.key(c, "itag-edit");
            const edit_btn = ui.div(c).row().px(5).py(2).rounded(4).hover(pal.row_hover).control();
            const eit = edit_btn.interaction();
            ui.text(c, if (picker.open) "Done" else "Edit…", .{ .size = 11.5, .color = pal.accent });
            edit_btn.end();
            if (eit.clicked) {
                picker.open = !picker.open;
                c.changed = true;
            }
        }
    }

    if (s.inspector.tag_mask != 0) {
        const applied = ui.div(c).row().wFull().gap(5).itemsCenter();
        defer applied.end();
        for (volumes.finder_tags) |t| {
            if ((s.inspector.tag_mask & (@as(u8, 1) << t.bit)) == 0) continue;
            const chip = ui.div(c).row().px(7).py(2.5).gap(5).itemsCenter().roundedFull().circular().bg(pal.badge_bg);
            ui.div(c).w(8).h(8).roundedFull().circular().bg(theme.tagColor(t.bit)).end();
            ui.text(c, t.name, .{ .size = 11.5, .color = pal.text });
            chip.end();
        }
    } else if (!picker.open) {
        ui.key(c, "itag-add");
        const add_row = ui.div(c).row().px(6).py(3).offset(-6, 0).rounded(5).hover(pal.row_hover).control();
        const ait = add_row.interaction();
        theme.describeNode(c, add_row.index, .button, "Add Tags…", "", false, true);
        ui.text(c, "Add Tags…", .{ .size = 12.5, .color = pal.subtle });
        add_row.end();
        if (ait.clicked) {
            picker.open = true;
            c.changed = true;
        }
    }

    if (picker.open) {
        const row = ui.div(c).row().wFull().pt(2).gap(6).itemsCenter();
        defer row.end();
        for (volumes.finder_tags) |t| {
            ui.key(c, c.print("itag-{d}", .{t.bit}));
            const on = (s.inspector.tag_mask & (@as(u8, 1) << t.bit)) != 0;
            const dot_col = theme.tagColor(t.bit);
            const btn = ui.div(c).w(22).h(22).roundedFull().circular().center().bg(if (on) dot_col else pal.bg.alpha(0)).hover(if (on) dot_col else pal.row_hover).control();
            const it = btn.interaction();
            theme.describeNode(c, btn.index, .checkbox, t.name, "", on, true);
            if (on) {
                ui.icon(c, "checkmark", .{ .size = 10, .weight = .bold, .color = ui.Color.white });
            } else {
                ui.div(c).w(12).h(12).roundedFull().circular().bg(dot_col).end();
            }
            btn.end();
            if (it.clicked) q.push(.{ .toggle_tag = t.bit });
        }
    }
}

fn preview(s: *const AppState, c: *ui.Context, pal: Palette, full_path: []const u8, media: *fs_media.MediaCache, q: *commands.Queue) void {
    const points_to_pixels: f32 = 2;
    if (media.preview.show(full_path, s.inspector.kind, s.inspector.mtime, @intFromFloat(content_w * points_to_pixels), @intFromFloat(preview_max_h * points_to_pixels))) |shot| {
        const w = @as(f32, @floatFromInt(shot.w)) / points_to_pixels;
        const h = @as(f32, @floatFromInt(shot.h)) / points_to_pixels;
        const frame = ui.div(c).row().wFull().h(h).justifyCenter().control();
        const it = frame.interaction();
        defer frame.end();
        _ = ui.image(c, .{
            .key = c.print("preview-{x}-{d}", .{ shot.key, shot.page }),
            .source = .{ .pixels = .{ .bgra = shot.bgra, .width = shot.w, .height = shot.h } },
            .box = .{ .w = w, .h = h },
            .radius = 4,
        });
        if (shot.pages > 1 and it.hovered) {
            const y = (h - theme.metric.page_btn_side) / 2;
            if (theme.pageTurnButton(c, "chevron.left", "Previous Page", 6, y, shot.page > 0)) q.push(.{ .turn_preview_page = -1 });
            if (theme.pageTurnButton(c, "chevron.right", "Next Page", content_w - theme.metric.page_btn_side - 6, y, shot.page + 1 < shot.pages)) q.push(.{ .turn_preview_page = 1 });
        }
        return;
    }

    if (s.inspector.is_text) {
        const sn = s.inspector.snippetText();
        const code_box = ui.div(c).wFull().p(10).rounded(6).bg(pal.code_bg).border(pal.divider).borderW(0.5).clip();
        ui.text(c, sn[0..@min(sn.len, 900)], .{ .size = 11, .mono = true, .color = pal.text, .wrap = true, .max_lines = 14 });
        code_box.end();
        return;
    }

    const kind_byte: u8 = s.inspector.kind;
    const frame = ui.div(c).row().wFull().py(14).justifyCenter();
    defer frame.end();
    file_icons.path(c, &media.icons, full_path, kind_byte, 128, theme.iconForPath(full_path, kind_byte, pal), null);
}

fn metaRow(c: *ui.Context, pal: Palette, key: []const u8, val: []const u8, divided: bool) void {
    if (divided) theme.hRule(c, pal.divider);
    const r = ui.div(c).row().wFull().h(24).justifyBetween().itemsCenter().gap(8);
    defer r.end();
    ui.text(c, key, .{ .size = theme.size.caption, .color = pal.muted });
    ui.text(c, val, .{ .size = theme.size.caption, .color = pal.text, .tabular = true, .truncate = .ellipsis });
}
