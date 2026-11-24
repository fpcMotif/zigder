const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const app_mod = @import("app.zig");
const AppState = app_mod.AppState;
const theme = @import("theme.zig");
const Palette = theme.Palette;
const fs_entry = @import("fs_entry.zig");
const file_icons = @import("file_icons.zig");

pub fn render(s: *AppState, c: *ui.Context, pal: Palette) void {
    const compact = c.size.w < 680;
    const cols = ui.div(c).column().sizeFull().bg(pal.bg);
    defer cols.end();

    {
        const hdr = ui.div(c).row().wFull().h(theme.metric.bar_h).px(theme.metric.pane_inset + 6).gap(8).itemsCenter().bg(pal.bg).border(pal.divider).borderW(0.5);
        defer hdr.end();

        sortHead(s, c, pal, "Name", .name, 0, .grow);
        if (!compact) sortHead(s, c, pal, "Date Modified", .modified, theme.metric.date_col_w, .start);
        sortHead(s, c, pal, "Size", .size, theme.metric.size_col_w, .end);
        if (!compact) sortHead(s, c, pal, "Kind", .kind, theme.metric.kind_col_w, .start);
    }

    const rows_slice = s.visibleRows();
    if (rows_slice.len == 0) {
        const empty_box = ui.div(c).column().sizeFull().center().gap(6);
        defer empty_box.end();
        ui.icon(c, theme.uiIconName("folder"), .{ .size = 28, .color = pal.subtle });
        ui.text(c, if (s.active_tag_filter != null) "No tagged items" else "Empty folder", .{ .size = 14, .color = pal.muted });
        return;
    }

    var activate_row: ?usize = null;
    var commit_rename = false;
    var list = ui.list(c, .{ .count = rows_slice.len, .row_height = theme.metric.row_h, .gap = 0, .padding = .xy(theme.metric.pane_inset, 2) });
    theme.listScrollbar(c, pal);
    while (list.next()) |r| {
        const eid = rows_slice[r];
        const ent = s.listing.entries.items[eid];
        const nm = s.listing.nameOf(ent);
        const sel = s.tabConst().selected.contains(eid);
        const bg_col = if (sel) pal.row_sel else if ((r & 1) == 1) pal.row_alt else pal.bg;
        const row = ui.div(c).row().wFull().h(theme.metric.row_h).px(6).gap(8).itemsCenter().rounded(theme.metric.row_radius).bg(bg_col).hover(if (sel) pal.row_sel else pal.row_hover).control();
        const it = row.interaction();
        theme.describeNode(c, row.index, .row, nm, theme.kindLabel(&s.listing, ent), sel, true);
        defer row.end();

        const fg = if (sel) pal.accent_text else pal.text;
        const muted = if (sel) pal.accent_text.alpha(0.85) else pal.muted;
        const ic = theme.iconForEntry(&s.listing, ent, pal);

        {
            const name_cell = ui.div(c).row().grow().gap(8).itemsCenter().clip();
            defer name_cell.end();
            file_icons.entry(c, &s.listing, ent, 16, ic, if (sel) pal.accent_text else null);
            if (s.renaming_row != null and s.renaming_row.? == r) {
                ui.key(c, "inline-rename");
                const rres = ui.textField(c, &s.rename_buf, .{
                    .width = .fill,
                    .size = 13,
                    .select_all_on_focus = true,
                });
                if (rres.submitted) commit_rename = true;
            } else {
                ui.text(c, nm, .{ .size = theme.size.body, .color = fg, .truncate = .middle });
            }
            if (ent.tag_mask != 0) {
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
            ui.text(c, theme.fmtMtime(c, ent.mtime), .{ .size = theme.size.body, .color = muted, .tabular = true });
        }

        {
            const sz_box = ui.div(c).row().w(theme.metric.size_col_w).px(4).justifyEnd();
            defer sz_box.end();
            if ((ent.flags & fs_entry.FLAG_SIZE_KNOWN) != 0) {
                ui.text(c, theme.fmtBytes(c, ent.size), .{ .size = theme.size.body, .color = muted, .tabular = true });
            } else {
                ui.text(c, "--", .{ .size = theme.size.body, .color = muted });
            }
        }

        if (!compact) {
            const kind_box = ui.div(c).row().w(theme.metric.kind_col_w).px(4).clip();
            defer kind_box.end();
            ui.text(c, theme.kindLabel(&s.listing, ent), .{ .size = theme.size.body, .color = muted, .truncate = .middle });
        }

        if (it.double_clicked) {
            activate_row = r;
        } else if (it.clicked or it.right_clicked) {
            s.selectRow(r, c.input.cmd, c.input.shift);
        }
    }
    list.end();
    if (commit_rename) {
        s.actionCommitRename();
    } else if (activate_row) |r| {
        s.selectRow(r, false, false);
        s.activateRow(r);
    }
}

fn sortHead(
    s: *AppState,
    c: *ui.Context,
    pal: Palette,
    label: []const u8,
    col: fs_entry.SortCol,
    width: f32,
    place: enum { grow, start, end },
) void {
    ui.key(c, label);
    var d = ui.div(c).row().gap(4).itemsCenter().px(4).py(2).rounded(4).hover(pal.row_hover).control();
    d = switch (place) {
        .grow => d.grow().justifyBetween(),
        .start => d.w(width),
        .end => d.w(width).justifyEnd(),
    };
    const it = d.interaction();
    theme.describeNode(c, d.index, .button, label, "", s.sort_col == col, true);
    defer d.end();

    const active = s.sort_col == col;
    ui.text(c, label, .{
        .size = theme.size.caption,
        .weight = if (active) .semibold else .regular,
        .color = if (active) pal.text else pal.muted,
    });
    if (active) {
        ui.icon(c, if (s.sort_asc) "chevron.up" else "chevron.down", .{ .size = 9, .color = pal.muted });
    }
    if (it.clicked) s.toggleSort(col);
}

pub fn renderSearch(s: *AppState, c: *ui.Context, pal: Palette) void {
    const compact = c.size.w < 680;
    const cols = ui.div(c).column().sizeFull().bg(pal.bg);
    defer cols.end();

    {
        const hdr = ui.div(c).row().wFull().h(32).px(12).gap(8).itemsCenter().justifyBetween().bg(pal.surface).border(pal.divider).borderW(0.5);
        defer hdr.end();

        ui.textf(c, .{ .size = 12, .weight = .medium, .color = pal.text, .tabular = true }, "{d} results in {d} us", .{
            s.search_results.hits.items.len,
            s.search_results.elapsed_us,
        });

        const scope_row = ui.div(c).row().gap(4).itemsCenter();
        defer scope_row.end();
        ui.key(c, "sc-disk");
        if (kit.button(c, "This Mac", .{
            .size = .xs,
            .variant = if (s.search_scope == .disk) .default else .ghost,
            .selected = s.search_scope == .disk,
        }).clicked) {
            s.search_scope = .disk;
            s.last_query.clearRetainingCapacity();
            s.updateInlineSearch();
        }
        ui.key(c, "sc-folder");
        if (kit.button(c, "Current Folder", .{
            .size = .xs,
            .variant = if (s.search_scope == .folder) .default else .ghost,
            .selected = s.search_scope == .folder,
        }).clicked) {
            s.search_scope = .folder;
            s.last_query.clearRetainingCapacity();
            s.updateInlineSearch();
        }
    }

    const hits = s.search_results.hits.items;
    if (hits.len == 0) {
        const empty_box = ui.div(c).column().sizeFull().center().gap(6);
        defer empty_box.end();
        ui.icon(c, "magnifyingglass", .{ .size = 28, .color = pal.subtle });
        ui.text(c, if (s.engine.ready.load(.acquire)) "No matching files" else "Index loading...", .{ .size = 14, .color = pal.muted });
        return;
    }

    var open_hit: ?usize = null;
    var list = ui.list(c, .{ .count = hits.len, .row_height = 36, .gap = 1, .padding = .xy(8, 4) });
    theme.listScrollbar(c, pal);
    while (list.next()) |i| {
        const hit = hits[i];
        const path = s.search_results.pathOf(hit);
        const nm = std.fs.path.basename(path);
        const dir = std.fs.path.dirname(path) orelse "/";
        const sel = i == s.search_cursor;
        const row = ui.div(c).row().wFull().h(36).px(8).gap(10).itemsCenter().rounded(6).bg(if (sel) pal.row_sel else if ((i & 1) == 1) pal.row_alt else pal.bg).hover(if (sel) pal.row_sel else pal.row_hover).control();
        const it = row.interaction();
        theme.describeNode(c, row.index, .row, nm, dir, sel, true);
        defer row.end();

        const fg = if (sel) pal.accent_text else pal.text;
        const muted = if (sel) pal.accent_text.alpha(0.85) else pal.muted;
        const ic = theme.iconForPath(path, hit.kind, pal);
        file_icons.path(c, path, hit.kind, 18, ic, if (sel) pal.accent_text else null);

        {
            const text_col = ui.div(c).column().grow().gap(1).clip();
            defer text_col.end();
            ui.text(c, nm, .{ .size = 13, .weight = .medium, .color = fg, .truncate = .ellipsis });
            ui.text(c, dir, .{ .size = 11, .color = muted, .truncate = .middle });
        }

        if (!compact) {
            ui.text(c, theme.fmtMtime(c, hit.mtime), .{ .size = 11.5, .color = muted, .tabular = true });
        }
        {
            const sz_box = ui.div(c).row().w(76).justifyEnd();
            defer sz_box.end();
            ui.text(c, theme.fmtBytes(c, hit.size), .{ .size = 11.5, .color = muted, .tabular = true });
        }

        if (it.double_clicked) {
            open_hit = i;
        } else if (it.clicked) {
            s.search_cursor = i;
            s.refreshInspector();
        }
    }
    list.end();
    if (open_hit) |i| s.openSearchHit(i);
}
