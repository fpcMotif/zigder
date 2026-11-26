const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const app_mod = @import("../app/app.zig");
const AppState = app_mod.AppState;
const commands = @import("../app/commands.zig");
const theme = @import("theme.zig");
const fs_media = @import("../fs/media.zig");
const file_icons = @import("file_icons.zig");
const Palette = theme.Palette;

pub fn render(
    s: *const AppState,
    c: *ui.Context,
    pal: Palette,
    icons: *fs_media.IconCache,
    modal_buf: *ui.TextBuffer,
    q: *commands.Queue,
) void {
    if (!s.overlay.isOpen()) return;

    const backdrop = ui.div(c).fixed().w(c.size.w).h(c.size.h).layer(10).bg(ui.Color.black.alpha(if (c.theme.dark) 0.48 else 0.22));
    const bit = backdrop.interaction();
    backdrop.end();
    if (bit.clicked) {
        q.push(.close_overlay);
        return;
    }

    switch (s.overlay.active) {
        .none => {},
        .go_or_search => |g| renderPalette(s, g.is_go, g.cursor, c, pal, icons, modal_buf, q),
        .new_folder => renderNewFolder(c, pal, modal_buf, q),
        .confirm_delete => |targets| renderDeleteConfirm(targets, c, pal, q),
    }
}

fn renderPalette(
    s: *const AppState,
    is_go: bool,
    cursor: usize,
    c: *ui.Context,
    pal: Palette,
    icons: *fs_media.IconCache,
    modal_buf: *ui.TextBuffer,
    q: *commands.Queue,
) void {
    const pw: f32 = @min(540, c.size.w - 32);
    const px = (c.size.w - pw) / 2;
    const py = @max(52.0, c.size.h * 0.14);

    const card = ui.div(c).fixed().offset(px, py).w(pw).maxH(420).layer(11).column().rounded(12).bg(pal.bg).border(pal.border).borderW(0.5).shadows(&ui.Shadow.lg).clip();
    _ = card.interaction();
    defer card.end();

    {
        const row = ui.div(c).row().wFull().px(14).py(11).itemsCenter().gap(10);
        defer row.end();
        ui.icon(c, if (is_go) "folder" else "magnifyingglass", .{ .size = 15, .weight = .medium, .color = pal.muted, .frame = 18 });
        ui.key(c, "modal-input");
        const tres = ui.textField(c, modal_buf, .{
            .placeholder = if (is_go) "Enter a folder path…" else "Search files by name…",
            .width = .fill,
            .size = 14,
            .bare = true,
            .select_all_on_focus = true,
        });
        if (tres.changed) q.push(.modal_search_changed);
        if (tres.submitted) q.push(.modal_commit);
    }

    const txt = modal_buf.text();
    if (txt.len > 0 and (txt[0] == '/' or txt[0] == '~')) {
        theme.hRule(c, pal.divider);
        const pad = ui.div(c).column().wFull().p(6);
        defer pad.end();
        const row = ui.div(c).row().wFull().h(34).px(10).gap(8).itemsCenter().rounded(6).bg(pal.row_sel).control();
        const rit = row.interaction();
        defer row.end();
        ui.icon(c, "arrow.right", .{ .size = 12, .weight = .semibold, .color = pal.accent_text });
        ui.textf(c, .{ .size = 13, .color = pal.accent_text, .truncate = .middle }, "Open {s}", .{txt});
        if (rit.clicked) q.push(.modal_commit);
        return;
    }

    const hits = s.overlay.results.hits.items;
    if (hits.len == 0) {
        if (txt.len > 0) {
            theme.hRule(c, pal.divider);
            const empty = ui.div(c).row().wFull().px(14).py(12);
            defer empty.end();
            ui.text(c, "No matching items", .{ .size = 12.5, .color = pal.subtle });
        }
        return;
    }

    theme.hRule(c, pal.divider);
    const list_h: f32 = @min(290, @as(f32, @floatFromInt(hits.len)) * 35 + 12);
    const list_wrap = ui.div(c).column().wFull().h(list_h + 4).pb(4).clip();
    defer list_wrap.end();
    var list = ui.list(c, .{ .count = hits.len, .row_height = 34, .gap = 1, .padding = .all(6), .height = .{ .px = list_h } });
    c.node(c.stack.items[c.stack.items.len - 1]).style.clip = true;
    theme.listScrollbar(c, pal);
    while (list.next()) |i| {
        const hit = hits[i];
        const path = s.overlay.results.pathOf(hit);
        const nm = std.fs.path.basename(path);
        const dir = std.fs.path.dirname(path) orelse "/";
        const sel = i == cursor;
        const ic = theme.iconForPath(path, hit.kind, pal);

        const row = ui.div(c).row().wFull().h(34).px(8).gap(9).itemsCenter().rounded(6).bg(if (sel) pal.row_sel else pal.bg.alpha(0)).hover(if (sel) pal.row_sel else pal.row_hover).control();
        const it = row.interaction();
        defer row.end();
        file_icons.path(c, icons, path, hit.kind, 18, ic, if (sel) pal.accent_text else null);
        {
            const text_col = ui.div(c).column().grow().gap(1).clip();
            defer text_col.end();
            ui.text(c, nm, .{ .size = 12.5, .weight = .medium, .color = if (sel) pal.accent_text else pal.text, .truncate = .ellipsis });
            ui.text(c, dir, .{ .size = 11, .color = if (sel) pal.accent_text.alpha(0.85) else pal.muted, .truncate = .middle });
        }
        if (it.clicked) {
            q.push(.{ .modal_pick_hit = i });
        }
    }
    list.end();
}

fn renderNewFolder(c: *ui.Context, pal: Palette, modal_buf: *ui.TextBuffer, q: *commands.Queue) void {
    const pw: f32 = @min(340, c.size.w - 32);
    const px = (c.size.w - pw) / 2;
    const py = @max(64.0, c.size.h * 0.24);
    const card = ui.div(c).fixed().offset(px, py).w(pw).layer(11).column().p(18).gap(12).rounded(12).bg(pal.bg).border(pal.border).borderW(0.5).shadows(&ui.Shadow.lg);
    _ = card.interaction();
    defer card.end();

    ui.text(c, "New Folder", .{ .size = 14, .weight = .semibold, .color = pal.text });
    ui.key(c, "nf-input");
    const tres = ui.textField(c, modal_buf, .{
        .placeholder = "Folder name",
        .width = .fill,
        .size = 13,
        .select_all_on_focus = true,
    });
    if (tres.submitted) {
        q.push(.commit_new_folder);
        return;
    }

    const actions = ui.div(c).row().wFull().pt(2).justifyEnd().gap(8);
    defer actions.end();
    if (kit.button(c, "Cancel", .{ .size = .sm }).clicked) {
        q.push(.close_overlay);
    }
    if (kit.button(c, "Create", .{ .size = .sm, .variant = .primary }).clicked) {
        q.push(.commit_new_folder);
    }
}

fn renderDeleteConfirm(targets: []const []u8, c: *ui.Context, pal: Palette, q: *commands.Queue) void {
    const pw: f32 = @min(340, c.size.w - 32);
    const px = (c.size.w - pw) / 2;
    const py = @max(64.0, c.size.h * 0.24);
    const card = ui.div(c).fixed().offset(px, py).w(pw).layer(11).column().p(18).gap(10).rounded(12).bg(pal.bg).border(pal.border).borderW(0.5).shadows(&ui.Shadow.lg);
    _ = card.interaction();
    defer card.end();

    ui.text(c, "Delete Immediately?", .{ .size = 14, .weight = .semibold, .color = pal.text });
    const style: ui.TextStyle = .{ .size = 12.5, .color = pal.muted, .wrap = true };
    if (targets.len == 1) {
        ui.text(c, "1 item will be deleted permanently. You can’t undo this action.", style);
    } else {
        ui.textf(c, style, "{d} items will be deleted permanently. You can’t undo this action.", .{targets.len});
    }

    const actions = ui.div(c).row().wFull().pt(4).justifyEnd().gap(8);
    defer actions.end();
    if (kit.button(c, "Cancel", .{ .size = .sm }).clicked) {
        q.push(.close_overlay);
    }
    if (kit.button(c, "Delete", .{ .size = .sm, .variant = .danger }).clicked) {
        q.push(.confirm_delete);
    }
}
