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

const col_w: f32 = 188;

pub fn render(s: *const AppState, c: *ui.Context, pal: Palette, icons: *fs_media.IconCache, q: *commands.Queue) void {
    const outer_id = c.peekId(null);
    const outer = ui.div(c).row().sizeFull().bg(pal.bg).clip();
    defer outer.end();

    const avail_w: f32 = if (c.rects.get(outer_id)) |r| r.w else @max(360, c.size.w - 500);
    const max_vis: usize = @max(@as(usize, 2), @as(usize, @intFromFloat(@floor(avail_w / col_w))));
    const start_idx: usize = if (s.columns.items.len > max_vis) s.columns.items.len - max_vis else 0;

    for (s.columns.items[start_idx..], start_idx..) |pane, pi| {
        ui.key(c, c.print("colpane-{d}", .{pi}));
        const pbox = ui.div(c).column().w(col_w).hFull().bg(pal.bg);
        defer theme.vRule(c, pal.divider);
        defer pbox.end();

        const focused_pane = pi + 1 == s.columns.items.len;
        const count = pane.listing.order.items.len;
        if (count == 0) {
            const empty_p = ui.div(c).column().sizeFull().center();
            ui.text(c, "Empty", .{ .size = 12, .color = pal.subtle });
            empty_p.end();
            continue;
        }

        var list = ui.list(c, .{ .count = count, .row_height = theme.metric.column_row_h, .gap = 0, .padding = .xy(6, 4) });
        theme.listScrollbar(c, pal);
        while (list.next()) |r| {
            const eid = pane.listing.order.items[r];
            const ent = pane.listing.entries.items[eid];
            const nm = pane.listing.nameOf(ent);
            const sel = pane.selected_row == r;
            const emphasized = sel and focused_pane;
            const sel_bg = if (emphasized) pal.row_sel else pal.row_sel_muted;
            const row = ui.div(c).row().wFull().h(theme.metric.column_row_h).px(6).gap(5).itemsCenter().justifyBetween().rounded(6).bg(if (sel) sel_bg else pal.bg).hover(if (sel) sel_bg else pal.row_hover).control();
            const it = row.interaction();
            theme.describeNode(c, row.index, .row, nm, "", sel, true);
            defer row.end();

            const fg = if (emphasized) pal.accent_text else pal.text;
            const ic = theme.iconForEntry(&pane.listing, ent, pal);
            {
                const left = ui.div(c).row().grow().gap(6).itemsCenter().clip();
                defer left.end();
                file_icons.entry(c, icons, &pane.listing, ent, 16, ic, if (emphasized) pal.accent_text else null);
                ui.text(c, nm, .{ .size = theme.size.body, .color = fg, .truncate = .middle });
            }
            if (ent.isFolderRow()) {
                ui.icon(c, "chevron.right", .{ .size = 7.5, .weight = .semibold, .color = if (emphasized) pal.accent_text else pal.subtle });
            }

            if (it.double_clicked and !ent.isFolderRow() and pi + 1 == s.columns.items.len) {
                q.push(.{ .select_column_row = .{ .pane = pi, .row = r } });
                q.push(.{ .select_only_name = nm });
                q.push(.{ .action = .open_selected });
            } else if (it.clicked or it.right_clicked) {
                var pbuf: [2048]u8 = undefined;
                if (ent.isFolderRow()) {
                    q.push(.{ .select_column_row = .{ .pane = pi, .row = r } });
                    if (index_read.joinBuf(&pbuf, pane.path, nm)) |full| {
                        q.push(.{ .navigate_to = full });
                    }
                } else if (pi + 1 == s.columns.items.len) {
                    q.push(.{ .select_column_row = .{ .pane = pi, .row = r } });
                    q.push(.{ .select_only_name = nm });
                } else {
                    q.push(.{ .navigate_and_select = .{ .path = pane.path, .name = nm } });
                }
            }
        }
        list.end();
    }
}
