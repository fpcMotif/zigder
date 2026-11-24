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
        const empty_box = ui.div(c).column().sizeFull().center();
        ui.text(c, "Empty folder", .{ .size = 14, .color = pal.muted });
        empty_box.end();
        return;
    }

    const stage = ui.div(c).column().grow().wFull().p(20).gap(12).center().bg(pal.surface).clip();
    {
        defer stage.end();
        if (s.entryAtRow(s.tab().cursor)) |cur| {
            const nm = s.listing.nameOf(cur.entry);
            const ic = theme.iconForEntry(&s.listing, cur.entry, pal);
            file_icons.entry(c, &s.listing, cur.entry, 64, ic, null);
            ui.text(c, nm, .{ .size = 18, .weight = .semibold, .color = pal.text, .truncate = .ellipsis });
            ui.textf(c, .{ .size = 13, .color = pal.muted, .tabular = true }, "{s} · {s} · Modified {s}", .{
                theme.kindLabel(&s.listing, cur.entry),
                theme.fmtBytes(c, cur.entry.size),
                theme.fmtMtime(c, cur.entry.mtime),
            });
            if (s.inspector.valid and s.inspector.is_text and s.inspector.snippetText().len > 0) {
                const sn = s.inspector.snippetText();
                const preview = sn[0..@min(sn.len, 600)];
                const code_box = ui.div(c).wFull().maxW(620).maxH(180).p(12).rounded(8).bg(pal.code_bg).border(pal.border).borderW(0.5).clip();
                ui.text(c, preview, .{ .size = 11.5, .mono = true, .color = pal.text, .wrap = true, .max_lines = 9 });
                code_box.end();
            }
        }
    }

    const strip = ui.div(c).column().wFull().h(154).bg(pal.bg).border(pal.divider).borderW(0.5);
    defer strip.end();
    var activate_row: ?usize = null;
    var list = ui.list(c, .{ .count = rows_slice.len, .row_height = 28, .gap = 2, .padding = .xy(10, 6) });
    theme.listScrollbar(c, pal);
    while (list.next()) |r| {
        const eid = rows_slice[r];
        const ent = s.listing.entries.items[eid];
        const nm = s.listing.nameOf(ent);
        const sel = r == s.tab().cursor;
        const ic = theme.iconForEntry(&s.listing, ent, pal);
        const row = ui.div(c).row().wFull().h(28).px(10).gap(8).itemsCenter().rounded(6).bg(if (sel) pal.row_sel else pal.bg).hover(if (sel) pal.row_sel else pal.row_hover).control();
        const it = row.interaction();
        theme.describeNode(c, row.index, .row, nm, "", sel, true);
        defer row.end();
        file_icons.entry(c, &s.listing, ent, 16, ic, if (sel) pal.accent_text else null);
        ui.text(c, nm, .{ .size = 13, .color = if (sel) pal.accent_text else pal.text, .truncate = .ellipsis });
        ui.spacer(c);
        ui.text(c, theme.fmtBytes(c, ent.size), .{ .size = 11.5, .color = if (sel) pal.accent_text else pal.muted, .tabular = true });
        if (it.double_clicked) {
            activate_row = r;
        } else if (it.clicked) {
            s.selectRow(r, false, false);
        }
    }
    list.end();
    if (activate_row) |r| {
        s.selectRow(r, false, false);
        s.activateRow(r);
    }
}
