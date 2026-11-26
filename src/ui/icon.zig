const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_mod = @import("../app/app.zig");
const AppState = app_mod.AppState;
const commands = @import("../app/commands.zig");
const theme = @import("theme.zig");
const Palette = theme.Palette;
const fs_media = @import("../fs/media.zig");
const file_icons = @import("file_icons.zig");

pub fn render(s: *const AppState, c: *ui.Context, pal: Palette, icons: *fs_media.IconCache, q: *commands.Queue) void {
    const outer = ui.div(c).column().sizeFull().bg(pal.bg);
    defer outer.end();

    const rows_slice = s.visibleRows();
    if (rows_slice.len == 0) {
        const empty_box = ui.div(c).column().sizeFull().center().gap(6);
        defer empty_box.end();
        ui.text(c, if (s.active_tag_filter != null) "No Tagged Items" else "Empty Folder", .{ .size = 13, .color = pal.subtle });
        return;
    }

    const box_id = c.peekId(null);
    const est_w: f32 = if (c.rects.get(box_id)) |r| r.w else @max(320, c.size.w - 500);
    const icon_pt: f32 = @round(s.icon_zoom * 0.76);
    const plate_side: f32 = icon_pt + 12;
    const tile_w: f32 = s.icon_zoom + 28;
    const tile_h: f32 = plate_side + 26;
    const grid_gap: f32 = 8;
    const cols: usize = @max(@as(usize, 1), @as(usize, @intFromFloat(@floor(@max(tile_w, est_w - 28) / (tile_w + grid_gap)))));
    const grid_rows = std.math.divCeil(usize, rows_slice.len, cols) catch unreachable;
    const plate_bg = pal.row_sel_muted.alpha(if (c.theme.dark) 0.65 else 0.55);

    var list = ui.list(c, .{ .count = grid_rows, .row_height = tile_h, .gap = 10, .padding = .xy(14, 14) });
    theme.listScrollbar(c, pal);
    while (list.next()) |gr| {
        const row_box = ui.div(c).row().wFull().h(tile_h).gap(grid_gap).itemsStart();
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
            const tile = ui.div(c).column().w(tile_w).h(tile_h).gap(4).itemsCenter().justifyCenter().control();
            const it = tile.interaction();
            theme.describeNode(c, tile.index, .button, nm, theme.kindLabel(&s.listing, ent), sel, true);
            defer tile.end();

            const icon_box = ui.div(c).w(plate_side).h(plate_side).center().rounded(8).bg(if (sel) plate_bg else pal.bg.alpha(0));
            file_icons.entry(c, icons, &s.listing, ent, icon_pt, ic, null);
            icon_box.end();

            const label = ui.div(c).row().maxW(tile_w - 6).px(6).py(1.5).gap(4).itemsCenter().rounded(5).bg(if (sel) pal.row_sel else pal.bg.alpha(0)).clip();
            ui.text(c, nm, .{
                .size = theme.size.callout,
                .color = if (sel) pal.accent_text else pal.text,
                .truncate = .middle,
            });
            if (ent.tag_mask != 0) {
                for (0..7) |b| {
                    if ((ent.tag_mask & (@as(u8, 1) << @intCast(b))) != 0) {
                        ui.div(c).w(6).h(6).roundedFull().circular().bg(theme.tagColor(@intCast(b))).end();
                    }
                }
            }
            label.end();

            if (it.double_clicked) {
                q.push(.{ .select_row = .{ .row = idx } });
                q.push(.{ .activate_row = idx });
            } else if (it.clicked or it.right_clicked) {
                q.push(.{ .select_row = .{ .row = idx, .toggle_cmd = c.input.cmd, .range_shift = c.input.shift } });
            }
        }
    }
    list.end();
}
