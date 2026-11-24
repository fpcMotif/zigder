const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_mod = @import("app.zig");
const AppState = app_mod.AppState;
const theme = @import("theme.zig");
const Palette = theme.Palette;
const file_icons = @import("file_icons.zig");

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

    var activate_row: ?usize = null;
    var list = ui.list(c, .{ .count = grid_rows, .row_height = tile_h, .gap = 10, .padding = .xy(12, 12) });
    theme.listScrollbar(c, pal);
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
            const tile = ui.div(c).column().w(tile_w).h(tile_h).p(4).gap(4).center().control();
            const it = tile.interaction();
            theme.describeNode(c, tile.index, .button, nm, theme.kindLabel(&s.listing, ent), sel, true);
            defer tile.end();

            const icon_box = ui.div(c).w(s.icon_zoom * 0.72).h(s.icon_zoom * 0.72).center().rounded(8).bg(if (sel) pal.text.alpha(0.1) else pal.bg.alpha(0));
            file_icons.entry(c, &s.listing, ent, s.icon_zoom * 0.64, ic, null);
            icon_box.end();

            const label = ui.div(c).row().maxW(tile_w - 8).px(4).py(1).rounded(5).bg(if (sel) pal.row_sel else pal.bg.alpha(0)).clip();
            ui.text(c, nm, .{
                .size = theme.size.callout,
                .color = if (sel) pal.accent_text else pal.text,
                .truncate = .middle,
            });
            label.end();

            if (it.double_clicked) {
                activate_row = idx;
            } else if (it.clicked) {
                s.selectRow(idx, c.input.cmd, c.input.shift);
            }
        }
    }
    list.end();
    if (activate_row) |idx| {
        s.selectRow(idx, false, false);
        s.activateRow(idx);
    }
}
