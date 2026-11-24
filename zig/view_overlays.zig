const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const app_mod = @import("app.zig");
const AppState = app_mod.AppState;
const theme = @import("theme.zig");
const Palette = theme.Palette;

pub fn render(s: *AppState, c: *ui.Context, pal: Palette) void {
    if (s.overlay == .none) return;

    const backdrop = ui.div(c).fixed().w(c.size.w).h(c.size.h).layer(10).bg(ui.Color.black.alpha(0.35));
    const bit = backdrop.interaction();
    backdrop.end();
    if (bit.clicked) {
        s.closeOverlay();
        return;
    }

    switch (s.overlay) {
        .none => {},
        .go_or_search => renderPalette(s, c, pal),
        .new_folder => renderNewFolder(s, c, pal),
        .confirm_delete => renderDeleteConfirm(s, c, pal),
    }
}

fn renderPalette(s: *AppState, c: *ui.Context, pal: Palette) void {
    const pw: f32 = @min(560, c.size.w - 32);
    const px = (c.size.w - pw) / 2;
    const py = @max(48.0, c.size.h * 0.14);

    const card = ui.div(c).fixed().offset(px, py).w(pw).maxH(440).layer(11).column().p(12).gap(10).rounded(12).bg(pal.surface).border(pal.border).borderW(1).shadowLg();
    _ = card.interaction();
    defer card.end();

    {
        const row = ui.div(c).row().wFull().itemsCenter().gap(8);
        defer row.end();
        ui.icon(c, if (s.modal_is_go) "folder" else "magnifyingglass", .{ .size = 15, .color = pal.accent });
        ui.key(c, "modal-input");
        const tres = ui.textField(c, &s.modal_buf, .{
            .placeholder = "Type a path (/ or ~) or search disk...",
            .width = .fill,
            .size = 14,
            .select_all_on_focus = true,
        });
        if (tres.changed) s.updateModalSearch();
        if (tres.submitted) s.commitModalGoOrSearch();
        ui.key(c, "modal-close");
        if (kit.iconButton(c, "xmark", .{ .size = .xs }).clicked) {
            s.closeOverlay();
            return;
        }
    }

    const txt = s.modal_buf.text();
    if (txt.len > 0 and (txt[0] == '/' or txt[0] == '~')) {
        const row = ui.div(c).row().wFull().px(8).py(8).gap(8).itemsCenter().rounded(8).bg(pal.bg).border(pal.divider).borderW(0.5);
        defer row.end();
        ui.icon(c, "arrow.right", .{ .size = 13, .color = pal.accent });
        ui.textf(c, .{ .size = 13, .color = pal.text }, "Open folder {s}", .{txt});
        return;
    }

    const hits = s.modal_results.hits.items;
    if (hits.len == 0) {
        const msg = if (txt.len == 0) "Instant search across indexed disk" else "No matches";
        ui.text(c, msg, .{ .size = 12.5, .color = pal.muted });
        return;
    }

    ui.textf(c, .{ .size = 11, .color = pal.subtle, .tabular = true }, "{d} matches in {d} us", .{ hits.len, s.modal_results.elapsed_us });
    const list_h: f32 = @min(300, @as(f32, @floatFromInt(hits.len)) * 34 + 8);
    var list = ui.list(c, .{ .count = hits.len, .row_height = 32, .gap = 2, .height = .{ .px = list_h } });
    while (list.next()) |i| {
        const hit = hits[i];
        const path = s.modal_results.pathOf(hit);
        const nm = std.fs.path.basename(path);
        const dir = std.fs.path.dirname(path) orelse "/";
        const sel = i == s.modal_cursor;
        const ic = theme.iconForPath(path, hit.kind, pal);

        const row = ui.div(c).row().wFull().h(32).px(8).gap(8).itemsCenter().rounded(6).bg(if (sel) pal.row_sel else pal.bg).hover(if (sel) pal.row_sel else pal.row_hover).control();
        const it = row.interaction();
        defer row.end();
        ui.icon(c, ic.name, .{ .size = 14, .color = if (sel) pal.accent_text else ic.color });
        {
            const text_col = ui.div(c).column().grow().gap(1).clip();
            defer text_col.end();
            ui.text(c, nm, .{ .size = 12.5, .weight = .medium, .color = if (sel) pal.accent_text else pal.text, .truncate = .ellipsis });
            ui.text(c, dir, .{ .size = 10.5, .color = if (sel) pal.accent_text.alpha(0.85) else pal.muted, .truncate = .middle });
        }
        if (it.clicked) {
            s.modal_cursor = i;
            s.commitModalGoOrSearch();
        }
    }
    list.end();
}

fn renderNewFolder(s: *AppState, c: *ui.Context, pal: Palette) void {
    const pw: f32 = @min(380, c.size.w - 32);
    const px = (c.size.w - pw) / 2;
    const py = @max(60.0, c.size.h * 0.25);
    const card = ui.div(c).fixed().offset(px, py).w(pw).layer(11).column().p(16).gap(12).rounded(12).bg(pal.surface).border(pal.border).borderW(1).shadowLg();
    _ = card.interaction();
    defer card.end();

    ui.text(c, "New Folder", .{ .size = 15, .weight = .semibold, .color = pal.text });
    ui.key(c, "nf-input");
    const tres = ui.textField(c, &s.modal_buf, .{
        .placeholder = "Folder name",
        .width = .fill,
        .size = 13.5,
        .select_all_on_focus = true,
    });
    if (tres.submitted) {
        s.actionNewFolder(s.modal_buf.text());
        s.closeOverlay();
        return;
    }

    const actions = ui.div(c).row().wFull().justifyEnd().gap(8);
    defer actions.end();
    if (kit.button(c, "Cancel", .{ .size = .sm }).clicked) {
        s.closeOverlay();
    }
    if (kit.button(c, "Create", .{ .size = .sm, .variant = .primary }).clicked) {
        s.actionNewFolder(s.modal_buf.text());
        s.closeOverlay();
    }
}

fn renderDeleteConfirm(s: *AppState, c: *ui.Context, pal: Palette) void {
    const pw: f32 = @min(380, c.size.w - 32);
    const px = (c.size.w - pw) / 2;
    const py = @max(60.0, c.size.h * 0.25);
    const card = ui.div(c).fixed().offset(px, py).w(pw).layer(11).column().p(16).gap(12).rounded(12).bg(pal.surface).border(pal.border).borderW(1).shadowLg();
    _ = card.interaction();
    defer card.end();

    ui.text(c, "Delete Immediately?", .{ .size = 15, .weight = .semibold, .color = pal.text });
    ui.textf(c, .{ .size = 13, .color = pal.muted, .wrap = true }, "Delete {d} selected item(s) permanently. This cannot be undone.", .{s.delete_targets.len});

    const actions = ui.div(c).row().wFull().justifyEnd().gap(8);
    defer actions.end();
    if (kit.button(c, "Cancel", .{ .size = .sm }).clicked) {
        s.closeOverlay();
    }
    if (kit.button(c, "Delete", .{ .size = .sm, .variant = .danger }).clicked) {
        s.actionDeleteConfirmed();
    }
}
