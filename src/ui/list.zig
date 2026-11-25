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
const file_icons = @import("file_icons.zig");

const row_px: f32 = 8;

pub fn render(
    s: *const AppState,
    c: *ui.Context,
    pal: Palette,
    icons: *fs_media.IconCache,
    rename_buf: *ui.TextBuffer,
    q: *commands.Queue,
) void {
    const compact = c.size.w < 680;
    const cols = ui.div(c).column().sizeFull().bg(pal.bg);
    defer cols.end();

    {
        const hdr = ui.div(c).row().wFull().h(theme.metric.bar_h).px(theme.metric.pane_inset + row_px).gap(8).itemsCenter().bg(pal.bg);
        defer hdr.end();

        sortHead(s, c, pal, "Name", .name, 0, .grow, q);
        if (!compact) sortHead(s, c, pal, "Date Modified", .modified, theme.metric.date_col_w, .start, q);
        sortHead(s, c, pal, "Size", .size, theme.metric.size_col_w, .end, q);
        if (!compact) sortHead(s, c, pal, "Kind", .kind, theme.metric.kind_col_w, .start, q);
    }
    theme.hRule(c, pal.divider);

    const rows_slice = s.visibleRows();
    if (rows_slice.len == 0) {
        const empty_box = ui.div(c).column().sizeFull().center().gap(6);
        defer empty_box.end();
        ui.text(c, if (s.active_tag_filter != null) "No Tagged Items" else "Empty Folder", .{ .size = 13, .color = pal.subtle });
        return;
    }

    var list = ui.list(c, .{ .count = rows_slice.len, .row_height = theme.metric.row_h, .gap = 0, .padding = .xy(theme.metric.pane_inset, 3) });
    theme.listScrollbar(c, pal);
    while (list.next()) |r| {
        const eid = rows_slice[r];
        const ent = s.listing.entries.items[eid];
        const nm = s.listing.nameOf(ent);
        const sel = s.tabConst().selected.contains(eid);
        const bg_col = if (sel) pal.row_sel else if ((r & 1) == 1) pal.row_alt else pal.bg;
        const row = ui.div(c).row().wFull().h(theme.metric.row_h).px(row_px).gap(8).itemsCenter().rounded(theme.metric.row_radius).bg(bg_col).hover(if (sel) pal.row_sel else pal.row_hover).control();
        const it = row.interaction();
        theme.describeNode(c, row.index, .row, nm, theme.kindLabel(&s.listing, ent), sel, true);
        defer row.end();

        const fg = if (sel) pal.accent_text else pal.text;
        const muted = if (sel) pal.accent_text.alpha(0.85) else pal.muted;
        const ic = theme.iconForEntry(&s.listing, ent, pal);

        {
            const name_cell = ui.div(c).row().grow().gap(7).itemsCenter().clip();
            defer name_cell.end();
            file_icons.entry(c, icons, &s.listing, ent, 16, ic, if (sel) pal.accent_text else null);
            if (s.rename.isRow(r)) {
                ui.key(c, "inline-rename");
                const rres = ui.textField(c, rename_buf, .{
                    .width = .fill,
                    .size = 13,
                    .select_all_on_focus = true,
                });
                if (rres.submitted) q.push(.commit_rename);
            } else {
                ui.text(c, nm, .{ .size = theme.size.body, .color = fg, .truncate = .middle });
            }
            if (ent.tag_mask != 0) {
                const dots = ui.div(c).row().gap(3).itemsCenter();
                defer dots.end();
                for (0..7) |b| {
                    if ((ent.tag_mask & (@as(u8, 1) << @intCast(b))) != 0) {
                        ui.div(c).w(7).h(7).roundedFull().circular().bg(theme.tagColor(@intCast(b))).end();
                    }
                }
            }
        }

        if (!compact) {
            const mt_box = ui.div(c).row().w(theme.metric.date_col_w).px(4).clip();
            defer mt_box.end();
            ui.text(c, theme.fmtMtime(c, ent.mtime), .{ .size = 12.5, .color = muted, .tabular = true });
        }

        {
            const sz_box = ui.div(c).row().w(theme.metric.size_col_w).px(4).justifyEnd();
            defer sz_box.end();
            if ((ent.flags & fs_entry.FLAG_SIZE_KNOWN) != 0) {
                ui.text(c, theme.fmtBytes(c, ent.size), .{ .size = 12.5, .color = muted, .tabular = true });
            } else {
                ui.text(c, "--", .{ .size = 12.5, .color = muted });
            }
        }

        if (!compact) {
            const kind_box = ui.div(c).row().w(theme.metric.kind_col_w).px(4).clip();
            defer kind_box.end();
            ui.text(c, theme.kindLabel(&s.listing, ent), .{ .size = 12.5, .color = muted, .truncate = .middle });
        }

        if (it.double_clicked) {
            q.push(.{ .select_row = .{ .row = r } });
            q.push(.{ .activate_row = r });
        } else if (it.clicked or it.right_clicked) {
            q.push(.{ .select_row = .{ .row = r, .toggle_cmd = c.input.cmd, .range_shift = c.input.shift } });
        }
    }
    list.end();
}

fn sortHead(
    s: *const AppState,
    c: *ui.Context,
    pal: Palette,
    label: []const u8,
    col: fs_entry.SortCol,
    width: f32,
    place: enum { grow, start, end },
    q: *commands.Queue,
) void {
    ui.key(c, label);
    var d = ui.div(c).row().gap(4).itemsCenter().py(3).rounded(4).hover(pal.row_hover).control();
    d = switch (place) {
        .grow => d.grow().pr(4).justifyBetween(),
        .start => d.w(width).px(4),
        .end => d.w(width).px(4).justifyEnd(),
    };
    const it = d.interaction();
    theme.describeNode(c, d.index, .button, label, "", s.sort_col == col, true);
    defer d.end();

    const active = s.sort_col == col;
    if (place == .end and active) {
        ui.icon(c, if (s.sort_asc) "chevron.up" else "chevron.down", .{ .size = 8.5, .weight = .semibold, .color = pal.muted });
    }
    ui.text(c, label, .{
        .size = theme.size.caption,
        .weight = if (active) .semibold else .medium,
        .color = if (active) pal.text else pal.muted,
    });
    if (place != .end and active) {
        ui.icon(c, if (s.sort_asc) "chevron.up" else "chevron.down", .{ .size = 8.5, .weight = .semibold, .color = pal.muted });
    }
    if (it.clicked) q.push(.{ .toggle_sort = col });
}

fn scopeBtn(
    c: *ui.Context,
    pal: Palette,
    key_id: []const u8,
    label: []const u8,
    selected: bool,
) bool {
    ui.key(c, key_id);
    const pill = ui.div(c).row().h(22).px(8).itemsCenter().rounded(5).bg(if (selected) pal.row_sel_muted else pal.bg.alpha(0)).hover(if (selected) pal.row_sel_muted else pal.row_hover).control();
    const it = pill.interaction();
    theme.describeNode(c, pill.index, .radio_button, label, "", selected, true);
    ui.text(c, label, .{
        .size = 12,
        .weight = if (selected) .semibold else .medium,
        .color = if (selected) pal.text else pal.muted,
    });
    pill.end();
    return it.clicked;
}

pub fn renderSearch(s: *const AppState, c: *ui.Context, pal: Palette, icons: *fs_media.IconCache, q: *commands.Queue) void {
    const compact = c.size.w < 680;
    const cols = ui.div(c).column().sizeFull().bg(pal.bg);
    defer cols.end();

    {
        const hdr = ui.div(c).row().wFull().h(30).px(12).gap(6).itemsCenter().bg(pal.chrome);
        defer hdr.end();

        ui.text(c, "Search:", .{ .size = 12, .weight = .semibold, .color = pal.muted });

        const scope_row = ui.div(c).row().gap(2).itemsCenter();
        defer scope_row.end();
        if (scopeBtn(c, pal, "sc-disk", "This Mac", s.search.scope == .disk)) {
            q.push(.{ .set_search_scope = .disk });
        }
        const cur_name = theme.displayName(s.currentPath());
        const folder_lbl = c.print("“{s}”", .{cur_name});
        if (scopeBtn(c, pal, "sc-folder", folder_lbl, s.search.scope == .folder)) {
            q.push(.{ .set_search_scope = .folder });
        }
    }
    theme.hRule(c, pal.divider);

    const hits = s.search.results.hits.items;
    if (hits.len == 0) {
        const empty_box = ui.div(c).column().sizeFull().center().gap(6);
        defer empty_box.end();
        ui.text(c, if (s.engine.status().ready) "No Results" else "Indexing…", .{ .size = 13, .color = pal.subtle });
        return;
    }

    var list = ui.list(c, .{ .count = hits.len, .row_height = 36, .gap = 0, .padding = .xy(theme.metric.pane_inset, 3) });
    theme.listScrollbar(c, pal);
    while (list.next()) |i| {
        const hit = hits[i];
        const path = s.search.results.pathOf(hit);
        const nm = std.fs.path.basename(path);
        const dir = std.fs.path.dirname(path) orelse "/";
        const sel = i == s.search.cursor;
        const row = ui.div(c).row().wFull().h(36).px(row_px).gap(9).itemsCenter().rounded(theme.metric.row_radius).bg(if (sel) pal.row_sel else if ((i & 1) == 1) pal.row_alt else pal.bg).hover(if (sel) pal.row_sel else pal.row_hover).control();
        const it = row.interaction();
        theme.describeNode(c, row.index, .row, nm, dir, sel, true);
        defer row.end();

        const fg = if (sel) pal.accent_text else pal.text;
        const muted = if (sel) pal.accent_text.alpha(0.85) else pal.muted;
        const ic = theme.iconForPath(path, hit.kind, pal);
        file_icons.path(c, icons, path, hit.kind, 18, ic, if (sel) pal.accent_text else null);

        {
            const text_col = ui.div(c).column().grow().gap(1).clip();
            defer text_col.end();
            ui.text(c, nm, .{ .size = 13, .weight = .medium, .color = fg, .truncate = .ellipsis });
            ui.text(c, dir, .{ .size = 11, .color = muted, .truncate = .middle });
        }

        if (!compact) {
            ui.text(c, theme.fmtMtime(c, hit.mtime), .{ .size = 12, .color = muted, .tabular = true });
        }
        {
            const sz_box = ui.div(c).row().w(84).justifyEnd();
            defer sz_box.end();
            ui.text(c, theme.fmtBytes(c, hit.size), .{ .size = 12, .color = muted, .tabular = true });
        }

        if (it.double_clicked) {
            q.push(.{ .open_search_hit = i });
        } else if (it.clicked or it.right_clicked) {
            q.push(.{ .select_search_hit = i });
        }
    }
    list.end();
}
