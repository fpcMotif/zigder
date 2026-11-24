const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_mod = @import("app.zig");
const AppState = app_mod.AppState;
const theme = @import("theme.zig");
const Palette = theme.Palette;

pub fn render(s: *AppState, c: *ui.Context, pal: Palette) void {
    const outer = ui.div(c).column().sizeFull().bg(pal.bg);
    defer outer.end();

    const rows_slice = s.visibleRows();
    if (rows_slice.len == 0) {
        const empty_box = ui.div(c).column().sizeFull().center().gap(6);
        defer empty_box.end();
        ui.icon(c, theme.uiIconName("folder"), .{ .size = 32, .color = pal.subtle });
        ui.text(c, "Empty folder", .{ .size = 14, .color = pal.muted });
        return;
    }

    const box_id = c.peekId(null);
    const est_w: f32 = if (c.rects.get(box_id)) |r| r.w else @max(320, c.size.w - 460);
    const tile_w: f32 = s.icon_zoom + 16;
    const tile_h: f32 = s.icon_zoom + 24;
    const cols: usize = @max(@as(usize, 1), @as(usize, @intFromFloat(@floor(@max(tile_w, est_w - 24) / (tile_w + 10)))));
    const grid_rows = std.math.divCeil(usize, rows_slice.len, cols) catch 0;

    var list = ui.list(c, .{ .count = grid_rows, .row_height = tile_h, .gap = 10, .padding = .xy(12, 12) });
    while (list.next()) |gr| {
        const row_box = ui.div(c).row().wFull().h(tile_h).gap(10).itemsStart();
        defer row_box.end();
        const base = gr * cols;
        for (0..cols) |ci| {
            const idx = base + ci;
            if (idx >= rows_slice.len) break;
            const eid = rows_slice[idx];
            const ent = s.listing.entries.items[eid];
            const nm = s.listing.nameOf(ent);
            const sel = s.tabConst().selected.contains(eid);
            const ic = theme.iconForEntry(&s.listing, ent, pal);

            ui.key(c, c.print("tile-{d}", .{idx}));
            const tile = ui.div(c).column().w(tile_w).h(tile_h).p(6).gap(6).center().rounded(10).bg(if (sel) pal.row_sel else pal.bg.alpha(0)).hover(if (sel) pal.row_sel else pal.row_hover).control();
            const it = tile.interaction();
            theme.describeNode(c, tile.index, .button, nm, theme.kindLabel(&s.listing, ent), sel, true);
            defer tile.end();

            const icon_box = ui.div(c).w(s.icon_zoom * 0.62).h(s.icon_zoom * 0.62).center().rounded(12).bg(if (sel) pal.bg.alpha(0.16) else pal.surface);
            ui.icon(c, ic.name, .{ .size = s.icon_zoom * 0.42, .color = if (sel) pal.accent_text else ic.color });
            icon_box.end();

            ui.text(c, nm, .{
                .size = 12,
                .weight = if (sel) .medium else .regular,
                .color = if (sel) pal.accent_text else pal.text,
                .truncate = .ellipsis,
            });

            if (it.double_clicked) {
                s.selectRow(idx, false, false);
                s.activateRow(idx);
            } else if (it.clicked) {
                s.selectRow(idx, c.input.cmd, c.input.shift);
            }
        }
    }
    list.end();
}
