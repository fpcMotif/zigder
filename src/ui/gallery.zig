const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_mod = @import("../app/app.zig");
const AppState = app_mod.AppState;
const commands = @import("../app/commands.zig");
const theme = @import("theme.zig");
const Palette = theme.Palette;
const fs_entry = @import("../fs/entry.zig");
const fs_media = @import("../fs/media.zig");
const index_read = @import("../index/read.zig");
const file_icons = @import("file_icons.zig");

const strip_h: f32 = 84;
const cell_w: f32 = 72;
const cell_h: f32 = 72;
const cell_gap: f32 = 6;
const strip_pad_x: f32 = 12;

const StripFollow = struct {
    last_cursor: usize = std.math.maxInt(usize),
};

pub fn render(
    s: *const AppState,
    c: *ui.Context,
    pal: Palette,
    media: *fs_media.MediaCache,
    inspector_open: bool,
    q: *commands.Queue,
) void {
    const outer = ui.div(c).column().sizeFull().bg(pal.bg);
    defer outer.end();

    const rows_slice = s.visibleRows();
    if (rows_slice.len == 0) {
        const empty_box = ui.div(c).column().sizeFull().center();
        ui.text(c, if (s.active_tag_filter != null) "No Tagged Items" else "Empty Folder", .{ .size = 13, .color = pal.subtle });
        empty_box.end();
        return;
    }

    const stage_id = c.peekId(null);
    const stage_rect = c.rects.get(stage_id);
    const stage_w: f32 = if (stage_rect) |r| r.w else @max(320, c.size.w - 520);
    const stage_h: f32 = if (stage_rect) |r| r.h else @max(220, c.size.h - 200);

    {
        const stage = ui.div(c).column().grow().wFull().p(24).gap(12).center().bg(pal.bg).clip();
        defer stage.end();

        if (s.entryAtRow(s.tabConst().cursor)) |cur| {
            const nm = s.listing.nameOf(cur.entry);
            const max_w = @max(160, stage_w - 64);
            const pad_h: f32 = if (inspector_open) 48 else 96;
            const max_h = @max(120, stage_h - pad_h);
            renderStageHero(s, c, pal, media, cur.entry, nm, max_w, max_h, q);

            if (!inspector_open) {
                const cap = ui.div(c).column().itemsCenter().gap(2).maxW(max_w).clip();
                defer cap.end();
                ui.text(c, nm, .{ .size = 14, .weight = .semibold, .color = pal.text, .truncate = .middle });
                if ((cur.entry.flags & fs_entry.FLAG_SIZE_KNOWN) != 0) {
                    ui.textf(c, .{ .size = 12, .color = pal.muted, .tabular = true }, "{s} · {s}", .{
                        theme.kindLabel(&s.listing, cur.entry),
                        theme.fmtBytes(c, cur.entry.size),
                    });
                } else {
                    ui.text(c, theme.kindLabel(&s.listing, cur.entry), .{ .size = 12, .color = pal.muted });
                }
            }
        }
    }

    theme.hRule(c, pal.divider);
    renderFilmstrip(s, c, pal, &media.icons, rows_slice, q);
}

fn renderStageHero(
    s: *const AppState,
    c: *ui.Context,
    pal: Palette,
    media: *fs_media.MediaCache,
    ent: fs_entry.DirEntry,
    nm: []const u8,
    max_w: f32,
    max_h: f32,
    q: *commands.Queue,
) void {
    var pbuf: [2048]u8 = undefined;
    if (index_read.joinBuf(&pbuf, s.listing.path, nm)) |full_path| {
        const scale: f32 = 2;
        if (media.preview.show(full_path, ent.kind, ent.mtime, @intFromFloat(max_w * scale), @intFromFloat(max_h * scale))) |shot| {
            const w = @as(f32, @floatFromInt(shot.w)) / scale;
            const h = @as(f32, @floatFromInt(shot.h)) / scale;
            const frame = ui.div(c).row().w(w).h(h).center().control();
            const it = frame.interaction();
            defer frame.end();
            _ = ui.image(c, .{
                .key = c.print("gal-preview-{x}-{d}", .{ shot.key, shot.page }),
                .source = .{ .pixels = .{ .bgra = shot.bgra, .width = shot.w, .height = shot.h } },
                .box = .{ .w = w, .h = h },
                .radius = 4,
            });
            if (shot.pages > 1 and it.hovered) {
                const y = (h - theme.metric.page_btn_side) / 2;
                if (theme.pageTurnButton(c, "chevron.left", "Previous Page", 8, y, shot.page > 0)) q.push(.{ .turn_preview_page = -1 });
                if (theme.pageTurnButton(c, "chevron.right", "Next Page", w - theme.metric.page_btn_side - 8, y, shot.page + 1 < shot.pages)) q.push(.{ .turn_preview_page = 1 });
            }
            return;
        }
    }

    if (s.inspector.is_text and s.inspector.snippetText().len > 0) {
        const sn = s.inspector.snippetText();
        const preview = sn[0..@min(sn.len, 1200)];
        const sheet = ui.div(c).wFull().maxW(@min(560, max_w)).maxH(@min(340, max_h)).p(16).rounded(8).bg(pal.surface).border(pal.divider).borderW(0.5).clip();
        ui.text(c, preview, .{ .size = 11.5, .mono = true, .color = pal.text, .wrap = true, .max_lines = 16 });
        sheet.end();
        return;
    }

    const ic = theme.iconForEntry(&s.listing, ent, pal);
    const hero_pt = @min(160, @min(max_w, max_h));
    file_icons.entry(c, &media.icons, &s.listing, ent, hero_pt, ic, null);
}

fn renderFilmstrip(
    s: *const AppState,
    c: *ui.Context,
    pal: Palette,
    icons: *fs_media.IconCache,
    rows_slice: []const u32,
    q: *commands.Queue,
) void {
    ui.key(c, "gallery-filmstrip");
    const strip_id = c.peekId(null);
    const view_w: f32 = if (c.rects.get(strip_id)) |r| r.w else @max(320, c.size.w - 500);
    const pitch: f32 = cell_w + cell_gap;
    const total_w = pitch * @as(f32, @floatFromInt(rows_slice.len)) - cell_gap + 2 * strip_pad_x;
    const max_scroll = @max(0, total_w - view_w);

    const follow = c.state(StripFollow, "gallery-follow");
    const cur = s.tabConst().cursor;
    var scroll_x = std.math.clamp(c.scroll_x.get(strip_id) orelse 0, 0, max_scroll);
    if (follow.last_cursor != cur) {
        follow.last_cursor = cur;
        const item_left = strip_pad_x + @as(f32, @floatFromInt(cur)) * pitch;
        const item_right = item_left + cell_w;
        if (item_left < scroll_x + strip_pad_x) {
            scroll_x = @max(0, item_left - strip_pad_x);
            c.setScroll(strip_id, .x, scroll_x);
        } else if (item_right > scroll_x + view_w - strip_pad_x) {
            scroll_x = @min(max_scroll, item_right - view_w + strip_pad_x);
            c.setScroll(strip_id, .x, scroll_x);
        }
    }

    _ = c.open(.{
        .direction = .row,
        .width = .fill,
        .height = .{ .px = strip_h },
        .padding = .xy(strip_pad_x, 6),
        .gap = cell_gap,
        .align_items = .center,
        .background = pal.chrome,
        .scroll_x = true,
        .scroll_bar = false,
    }, null);
    defer c.end();

    const first_vis: usize = @intFromFloat(@floor(@max(0, scroll_x - strip_pad_x) / pitch));
    const vis_cnt: usize = @intFromFloat(@ceil(view_w / pitch) + 1);
    const overscan: usize = 4;
    const first = first_vis -| overscan;
    const last = @min(rows_slice.len, first_vis + vis_cnt + overscan);

    if (first > 0) {
        _ = c.leaf(.{ .width = .{ .px = pitch * @as(f32, @floatFromInt(first)) - cell_gap }, .height = .{ .px = 1 } }, .none, "strip-before");
    }

    for (first..last) |r| {
        const eid = rows_slice[r];
        const ent = s.listing.entries.items[eid];
        const nm = s.listing.nameOf(ent);
        const sel = r == cur;
        const ic = theme.iconForEntry(&s.listing, ent, pal);

        ui.keyInt(c, r);
        const cell = ui.div(c).column().w(cell_w).h(cell_h).gap(3).itemsCenter().justifyCenter().control();
        const it = cell.interaction();
        theme.describeNode(c, cell.index, .button, nm, theme.kindLabel(&s.listing, ent), sel, true);
        defer cell.end();

        var well = ui.div(c).w(50).h(50).center().rounded(8).bg(if (sel) pal.row_sel_muted else pal.bg.alpha(0)).hover(if (sel) pal.row_sel_muted else pal.row_hover);
        if (sel) {
            well = well.border(pal.accent).borderW(1.5);
        }
        file_icons.entry(c, icons, &s.listing, ent, 38, ic, null);
        well.end();

        const lbl = ui.div(c).row().maxW(cell_w - 4).justifyCenter().clip();
        ui.text(c, nm, .{
            .size = 11,
            .weight = if (sel) .medium else .regular,
            .color = if (sel) pal.text else pal.muted,
            .truncate = .middle,
        });
        lbl.end();

        if (it.double_clicked) {
            q.push(.{ .select_row = .{ .row = r } });
            q.push(.{ .activate_row = r });
        } else if (it.clicked or it.right_clicked) {
            q.push(.{ .select_row = .{ .row = r, .toggle_cmd = c.input.cmd, .range_shift = c.input.shift } });
        }
    }

    const after = rows_slice.len - last;
    if (after > 0) {
        _ = c.leaf(.{ .width = .{ .px = pitch * @as(f32, @floatFromInt(after)) - cell_gap }, .height = .{ .px = 1 } }, .none, "strip-after");
    }
}
