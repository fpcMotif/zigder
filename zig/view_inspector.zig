const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_mod = @import("app.zig");
const AppState = app_mod.AppState;
const theme = @import("theme.zig");
const Palette = theme.Palette;
const volumes = @import("volumes.zig");
const file_icons = @import("file_icons.zig");

pub fn render(s: *AppState, c: *ui.Context, pal: Palette) void {
    const pane = ui.div(c).column().w(288).hFull().p(theme.metric.pane_inset).gap(12).bg(pal.surface).border(pal.divider).borderW(0.5).scrollY().scrollbar(theme.scrollbar(pal));
    defer pane.end();

    if (!s.inspector.valid) {
        ui.text(c, "No selection", .{ .size = 13, .color = pal.muted });
        return;
    }

    const full_path = s.inspector_path.items;
    const base = if (std.mem.eql(u8, full_path, "/")) "Macintosh HD" else std.fs.path.basename(full_path);
    const kind_byte: u8 = if (s.inspector.is_dir) 1 else 0;
    const ic = theme.iconForPath(full_path, kind_byte, pal);

    {
        const hero = ui.div(c).column().wFull().py(10).gap(6).center().rounded(10).bg(pal.bg).border(pal.divider).borderW(0.5);
        defer hero.end();
        file_icons.path(c, full_path, kind_byte, 64, ic, null);
        ui.text(c, base, .{ .size = theme.size.title, .weight = .semibold, .color = pal.text, .truncate = .middle });
        ui.text(c, s.inspector.kindText(), .{ .size = theme.size.body, .color = pal.muted });
    }

    {
        const meta = ui.div(c).column().wFull().gap(6);
        defer meta.end();
        ui.text(c, "Information", .{ .size = 11.5, .weight = .semibold, .color = pal.subtle });
        metaRow(c, pal, "Size", theme.fmtBytes(c, s.inspector.size));
        metaRow(c, pal, "On Disk", theme.fmtBytes(c, s.inspector.alloc));
        if (s.inspector.is_dir) {
            metaRow(c, pal, "Items", c.print("{d}", .{s.inspector.dir_items}));
        }
        if (s.inspector.image_w > 0 and s.inspector.image_h > 0) {
            metaRow(c, pal, "Dimensions", c.print("{d} x {d}", .{ s.inspector.image_w, s.inspector.image_h }));
        }
        metaRow(c, pal, "Modified", theme.fmtMtime(c, s.inspector.mtime));
        metaRow(c, pal, "Mode", c.print("{o:0>4}", .{s.inspector.mode}));
    }

    {
        const tag_sec = ui.div(c).column().wFull().gap(6);
        defer tag_sec.end();
        ui.text(c, "Tags", .{ .size = 11.5, .weight = .semibold, .color = pal.subtle });
        const row = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer row.end();
        for (volumes.finder_tags) |t| {
            ui.key(c, c.print("itag-{d}", .{t.bit}));
            const on = (s.inspector.tag_mask & (@as(u8, 1) << t.bit)) != 0;
            const dot_col = theme.tagColor(t.bit);
            const btn = ui.div(c).w(20).h(20).roundedFull().circular().center().bg(if (on) dot_col else pal.bg).border(dot_col).borderW(if (on) 2 else 1).control();
            const it = btn.interaction();
            theme.describeNode(c, btn.index, .checkbox, t.name, "", on, true);
            if (on) {
                ui.icon(c, "checkmark", .{ .size = 10, .color = ui.Color.white });
            } else {
                ui.div(c).w(8).h(8).roundedFull().circular().bg(dot_col).end();
            }
            btn.end();
            if (it.clicked) s.actionToggleTag(t.bit);
        }
    }

    if (s.inspector.is_text and s.inspector.snippetText().len > 0) {
        const sn = s.inspector.snippetText();
        const capped = sn[0..@min(sn.len, 900)];
        const prev_sec = ui.div(c).column().wFull().gap(6);
        defer prev_sec.end();
        ui.text(c, "Preview", .{ .size = 11.5, .weight = .semibold, .color = pal.subtle });
        const code_box = ui.div(c).wFull().p(8).rounded(8).bg(pal.code_bg).border(pal.border).borderW(0.5).clip();
        ui.text(c, capped, .{ .size = 11, .mono = true, .color = pal.text, .wrap = true, .max_lines = 14 });
        code_box.end();
    }
}

fn metaRow(c: *ui.Context, pal: Palette, key: []const u8, val: []const u8) void {
    const r = ui.div(c).row().wFull().justifyBetween().itemsCenter().gap(8);
    defer r.end();
    ui.text(c, key, .{ .size = theme.size.caption, .color = pal.muted });
    ui.text(c, val, .{ .size = theme.size.caption, .color = pal.text, .tabular = true, .truncate = .ellipsis });
}
