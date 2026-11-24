const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_mod = @import("app.zig");
const AppState = app_mod.AppState;
const app_sel = @import("app_sel.zig");
const theme = @import("theme.zig");
const Palette = theme.Palette;
const fs_entry = @import("fs_entry.zig");
const file_icons = @import("file_icons.zig");

pub fn render(s: *AppState, c: *ui.Context, pal: Palette) void {
    const outer = ui.div(c).row().sizeFull().bg(pal.bg).clip();
    defer outer.end();

    if (s.columns.items.len == 0) {
        s.rebuildColumns();
    }

    var pending_buf: [2048]u8 = undefined;
    var pending_path: ?[]const u8 = null;
    var pending_name_buf: [256]u8 = undefined;
    var pending_name: ?[]const u8 = null;

    const max_vis: usize = if (c.size.w < 740) 2 else 4;
    const start_idx: usize = if (s.columns.items.len > max_vis) s.columns.items.len - max_vis else 0;

    for (s.columns.items[start_idx..], start_idx..) |*pane, pi| {
        ui.key(c, c.print("colpane-{d}", .{pi}));
        const col_w: f32 = 164;
        const pbox = ui.div(c).column().w(col_w).hFull().bg(pal.bg).border(pal.divider).borderW(0.5);
        defer pbox.end();

        const focused_pane = pi + 1 == s.columns.items.len;
        const count = pane.listing.order.items.len;
        if (count == 0) {
            const empty_p = ui.div(c).column().sizeFull().center();
            ui.text(c, "Empty", .{ .size = 12, .color = pal.subtle });
            empty_p.end();
            continue;
        }

        var list = ui.list(c, .{ .count = count, .row_height = theme.metric.column_row_h, .gap = 0, .padding = .xy(7, 4) });
        theme.listScrollbar(c, pal);
        while (list.next()) |r| {
            const eid = pane.listing.order.items[r];
            const ent = pane.listing.entries.items[eid];
            const nm = pane.listing.nameOf(ent);
            const sel = if (pane.selected_row) |sr| sr == r else false;
            const emphasized = sel and focused_pane;
            const sel_bg = if (emphasized) pal.row_sel else pal.row_sel_muted;
            const row = ui.div(c).row().wFull().h(theme.metric.column_row_h).px(6).gap(4).itemsCenter().justifyBetween().rounded(7).bg(if (sel) sel_bg else pal.bg).hover(if (sel) sel_bg else pal.row_hover).control();
            const it = row.interaction();
            theme.describeNode(c, row.index, .row, nm, "", sel, true);
            defer row.end();

            const fg = if (emphasized) pal.accent_text else pal.text;
            const ic = theme.iconForEntry(&pane.listing, ent, pal);
            {
                const left = ui.div(c).row().grow().gap(6).itemsCenter().clip();
                defer left.end();
                file_icons.entry(c, &pane.listing, ent, 16, ic, if (emphasized) pal.accent_text else null);
                ui.text(c, nm, .{ .size = theme.size.body, .color = fg, .truncate = .middle });
            }
            if (ent.isFolderRow()) {
                ui.icon(c, "chevron.right", .{ .size = 7, .weight = .semibold, .color = if (emphasized) pal.accent_text else pal.subtle });
            }

            if (it.clicked) {
                pane.selected_row = r;
                if (ent.isFolderRow()) {
                    pending_path = app_mod.joinBuf(&pending_buf, pane.path, nm);
                } else if (pi + 1 == s.columns.items.len) {
                    app_sel.selectOnlyName(s, nm);
                } else if (nm.len <= pending_name_buf.len and pane.path.len <= pending_buf.len) {
                    @memcpy(pending_buf[0..pane.path.len], pane.path);
                    pending_path = pending_buf[0..pane.path.len];
                    @memcpy(pending_name_buf[0..nm.len], nm);
                    pending_name = pending_name_buf[0..nm.len];
                }
            }
        }
        list.end();
    }

    const tail = ui.div(c).column().grow().hFull().p(16).gap(8).bg(pal.surface);
    defer tail.end();
    if (s.inspector.valid) {
        const nm = std.fs.path.basename(s.inspector_path.items);
        const ic = theme.iconForPath(s.inspector_path.items, if (s.inspector.is_dir) 1 else 0, pal);
        file_icons.path(c, s.inspector_path.items, if (s.inspector.is_dir) 1 else 0, 64, ic, null);
        ui.text(c, nm, .{ .size = 15, .weight = .semibold, .color = pal.text, .wrap = true });
        ui.text(c, s.inspector.kindText(), .{ .size = 12.5, .color = pal.muted });
        ui.text(c, theme.fmtBytes(c, s.inspector.size), .{ .size = 12.5, .color = pal.muted, .tabular = true });
    } else {
        ui.text(c, "Select an item", .{ .size = 13, .color = pal.subtle });
    }

    if (pending_path) |next| {
        s.navigateTo(next, true) catch return;
        if (pending_name) |nm| app_sel.selectOnlyName(s, nm);
    }
}
