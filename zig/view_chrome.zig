const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const app_mod = @import("app.zig");
const AppState = app_mod.AppState;
const ViewMode = app_mod.ViewMode;
const theme = @import("theme.zig");
const Palette = theme.Palette;
const volumes = @import("volumes.zig");
const fs_entry = @import("fs_entry.zig");

pub fn iconBtn(
    c: *ui.Context,
    icon_name: []const u8,
    a11y_label: []const u8,
    opts: kit.ButtonOptions,
) ui.Interaction {
    const idx: u32 = @intCast(c.nodes.items.len);
    const it = kit.iconButton(c, icon_name, opts);
    theme.describeNode(c, idx, .button, a11y_label, "", opts.selected, !opts.disabled);
    return it;
}

pub fn toolbar(s: *AppState, c: *ui.Context, pal: Palette) void {
    const compact = c.size.w < 740;
    const bar = ui.div(c).row().wFull().h(44).itemsCenter().justifyBetween().pl(if (compact) 74 else 80).pr(12).gap(8).bg(pal.chrome).border(pal.divider).borderW(0.5);
    defer bar.end();

    {
        const left = ui.div(c).row().itemsCenter().gap(6);
        defer left.end();
        ui.key(c, "tb-sidebar");
        if (iconBtn(c, "sidebar.left", "Toggle Sidebar", .{
            .size = .sm,
            .selected = s.show_sidebar,
        }).clicked) {
            s.show_sidebar = !s.show_sidebar;
        }
        ui.key(c, "tb-back");
        if (iconBtn(c, "chevron.left", "Back", .{
            .size = .sm,
            .disabled = !s.tabConst().canBack(),
        }).clicked) {
            s.goBack();
        }
        ui.key(c, "tb-fwd");
        if (iconBtn(c, "chevron.right", "Forward", .{
            .size = .sm,
            .disabled = !s.tabConst().canForward(),
        }).clicked) {
            s.goForward();
        }
        const cur_name = if (std.mem.eql(u8, s.currentPath(), "/"))
            "Macintosh HD"
        else
            std.fs.path.basename(s.currentPath());
        ui.text(c, cur_name, .{
            .size = 14,
            .weight = .semibold,
            .color = pal.text,
            .truncate = .ellipsis,
        });
    }

    if (!compact and s.tabs.items.len > 1) {
        const tab_strip = ui.div(c).row().itemsCenter().gap(4);
        defer tab_strip.end();
        for (s.tabs.items, 0..) |t, ti| {
            ui.key(c, c.print("win-tab-{d}", .{ti}));
            const on = ti == s.active_tab;
            const title = if (std.mem.eql(u8, t.path, "/")) "/" else std.fs.path.basename(t.path);
            const pill = ui.div(c).row().itemsCenter().gap(6).px(10).py(4).rounded(6).bg(if (on) pal.surface else pal.chrome).border(if (on) pal.border else pal.chrome).control();
            const pit = pill.interaction();
            defer pill.end();
            ui.text(c, title, .{ .size = 12, .weight = if (on) .semibold else .regular, .color = if (on) pal.text else pal.muted });
            if (pit.clicked) s.switchTab(ti);
        }
    }

    {
        const right = ui.div(c).row().itemsCenter().gap(6);
        defer right.end();

        {
            const views = ui.div(c).row().itemsCenter().gap(2).p(2).rounded(7).bg(pal.badge_bg);
            defer views.end();
            const specs = [_]struct { mode: ViewMode, icon: []const u8, lbl: []const u8 }{
                .{ .mode = .icon, .icon = "square.grid.2x2", .lbl = "Icon View" },
                .{ .mode = .list, .icon = "list.bullet", .lbl = "List View" },
                .{ .mode = .column, .icon = "rectangle.split.2x1", .lbl = "Column View" },
                .{ .mode = .gallery, .icon = "photo", .lbl = "Gallery View" },
            };
            for (specs, 0..) |sp, idx| {
                ui.key(c, c.print("vm-{d}", .{idx}));
                const selected = s.view_mode == sp.mode;
                if (iconBtn(c, sp.icon, sp.lbl, .{
                    .size = .xs,
                    .selected = selected,
                    .variant = if (selected) .default else .ghost,
                }).clicked) {
                    s.setViewMode(sp.mode);
                }
            }
        }

        if (!compact) {
            ui.key(c, "tb-palette");
            if (iconBtn(c, "command", "Quick Open", .{ .size = .sm }).clicked) {
                s.openModalSearch(false);
            }
        }

        const search_w: f32 = if (compact) 136 else 220;
        {
            const sbox = ui.div(c).row().itemsCenter().gap(4);
            defer sbox.end();
            ui.key(c, "tb-search");
            const sres = ui.textField(c, &s.search_buf, .{
                .placeholder = "Search Mac",
                .width = .{ .px = search_w },
                .size = 12.5,
                .select_all_on_focus = true,
            });
            if (sres.changed) s.updateInlineSearch();
            if (sres.submitted and s.isSearchActive()) s.openSearchHit(s.search_cursor);
            if (s.isSearchActive()) {
                ui.key(c, "tb-clear");
                if (iconBtn(c, "xmark", "Clear Search", .{ .size = .xs }).clicked) {
                    s.search_buf.clear();
                    s.updateInlineSearch();
                }
            }
        }

        ui.key(c, "tb-inspector");
        if (iconBtn(c, "info.circle", "Toggle Inspector", .{
            .size = .sm,
            .selected = s.show_inspector,
        }).clicked) {
            s.show_inspector = !s.show_inspector;
        }
    }
}

pub fn sidebar(s: *AppState, c: *ui.Context, pal: Palette) void {
    var box = ui.div(c).column().w(208).hFull().py(10).px(8).gap(4).border(pal.divider).borderW(0.5).scrollY();
    box = box.bg(pal.surface);
    defer box.end();

    sectionTitle(c, "Favorites", pal);
    for (s.sidebar, 0..) |item, i| {
        if (item.kind != .favorite) continue;
        sidebarRow(s, c, pal, item, i);
    }

    sectionTitle(c, "Locations", pal);
    for (s.sidebar, 0..) |item, i| {
        if (item.kind != .location) continue;
        sidebarRow(s, c, pal, item, i);
    }

    sectionTitle(c, "Tags", pal);
    for (s.sidebar, 0..) |item, i| {
        if (item.kind != .tag) continue;
        sidebarTagRow(s, c, pal, item, i);
    }

    ui.spacer(c);
    const foot = ui.div(c).row().wFull().px(8).pt(8).gap(6).itemsCenter();
    defer foot.end();
    const total = s.engine.entry_count.load(.acquire);
    const badge_txt = if (total > 0)
        c.print("{d} indexed", .{total})
    else if (s.engine.indexing.load(.acquire))
        "Indexing disk..."
    else
        "Folder mode";
    ui.text(c, badge_txt, .{ .size = 11, .color = pal.subtle, .tabular = true });
}

fn sectionTitle(c: *ui.Context, title: []const u8, pal: Palette) void {
    const h = ui.div(c).row().wFull().px(8).pt(8).pb(2);
    defer h.end();
    ui.text(c, title, .{ .size = 11, .weight = .semibold, .color = pal.subtle });
}

fn sidebarRow(s: *AppState, c: *ui.Context, pal: Palette, item: volumes.SidebarItem, idx: usize) void {
    ui.key(c, c.print("sb-{d}", .{idx}));
    const active = s.active_tag_filter == null and std.mem.eql(u8, s.currentPath(), item.path);
    const row = ui.div(c).row().wFull().px(8).py(5).gap(8).itemsCenter().rounded(6).bg(if (active) pal.row_sel else pal.bg.alpha(0)).hover(if (active) pal.row_sel else pal.row_hover).control();
    const it = row.interaction();
    theme.describeNode(c, row.index, .row, item.label, item.path, active, true);
    defer row.end();
    ui.icon(c, theme.uiIconName(item.icon), .{
        .size = 14,
        .color = if (active) pal.accent_text else pal.accent,
        .frame = 16,
    });
    const text_col = if (active) pal.accent_text else pal.text;
    const sub_col = if (active) pal.accent_text.alpha(0.85) else pal.subtle;
    if (item.kind == .location and item.total_bytes > 0) {
        const col = ui.div(c).column().grow().gap(1);
        defer col.end();
        ui.text(c, item.label, .{ .size = 12.5, .weight = if (active) .medium else .regular, .color = text_col, .truncate = .ellipsis });
        ui.textf(c, .{ .size = 10.5, .color = sub_col, .tabular = true }, "{s} free", .{theme.fmtBytes(c, item.free_bytes)});
    } else {
        ui.text(c, item.label, .{ .size = 12.5, .weight = if (active) .medium else .regular, .color = text_col, .truncate = .ellipsis });
    }
    if (it.clicked) {
        s.navigateTo(item.path, true) catch {};
    }
}

fn sidebarTagRow(s: *AppState, c: *ui.Context, pal: Palette, item: volumes.SidebarItem, idx: usize) void {
    ui.key(c, c.print("sbt-{d}", .{idx}));
    const active = s.active_tag_filter == item.tag_bit;
    const row = ui.div(c).row().wFull().px(8).py(4).gap(8).itemsCenter().rounded(6).bg(if (active) pal.row_sel_muted else pal.bg.alpha(0)).hover(pal.row_hover).control();
    const it = row.interaction();
    theme.describeNode(c, row.index, .row, item.label, "Tag", active, true);
    defer row.end();
    const dot = ui.div(c).w(10).h(10).roundedFull().circular().bg(theme.tagColor(item.tag_bit));
    dot.end();
    ui.text(c, item.label, .{ .size = 12.5, .weight = if (active) .medium else .regular, .color = pal.text });
    if (it.clicked) s.setTagFilter(item.tag_bit);
}

pub fn bottomBars(s: *AppState, c: *ui.Context, pal: Palette) void {
    const compact = c.size.w < 740;
    if (s.show_path_bar and !compact) {
        const pbar = ui.div(c).row().wFull().h(26).px(12).gap(4).itemsCenter().bg(pal.surface).border(pal.divider).borderW(0.5);
        defer pbar.end();

        const cur = s.currentPath();
        var nav_target: ?[]const u8 = null;
        const root_btn = ui.div(c).row().px(4).py(2).rounded(4).hover(pal.row_hover).control();
        const rit = root_btn.interaction();
        ui.icon(c, theme.uiIconName("internaldrive"), .{ .size = 11, .color = pal.muted });
        root_btn.end();
        if (rit.clicked) nav_target = "/";

        var acc_end: usize = 0;
        var iter = std.mem.tokenizeScalar(u8, cur, '/');
        var seg_idx: usize = 0;
        while (iter.next()) |comp| {
            acc_end = (@intFromPtr(comp.ptr) - @intFromPtr(cur.ptr)) + comp.len;
            const target_slice = cur[0..acc_end];
            ui.icon(c, "chevron.right", .{ .size = 9, .color = pal.subtle });
            ui.key(c, c.print("pb-{d}", .{seg_idx}));
            seg_idx += 1;
            const seg = ui.div(c).row().px(5).py(2).rounded(4).hover(pal.row_hover).control();
            const sit = seg.interaction();
            ui.text(c, comp, .{ .size = 11.5, .color = if (acc_end == cur.len) pal.text else pal.muted });
            seg.end();
            if (sit.clicked and !std.mem.eql(u8, target_slice, cur)) {
                nav_target = target_slice;
            }
        }
        if (nav_target) |target| s.navigateTo(target, true) catch {};
    }

    if (s.show_status_bar) {
        const sbar = ui.div(c).row().wFull().h(24).px(12).itemsCenter().justifyBetween().bg(pal.chrome).border(pal.divider).borderW(0.5);
        defer sbar.end();
        if (s.isSearchActive()) {
            ui.textf(c, .{ .size = 11, .color = pal.muted, .tabular = true }, "{d} matches · {d} us · Tier {d}", .{
                s.search_results.hits.items.len,
                s.search_results.elapsed_us,
                s.search_results.tier_used,
            });
        } else {
            const rows = s.visibleRows();
            const sel_cnt = s.tabConst().selected.count();
            if (sel_cnt > 1) {
                ui.textf(c, .{ .size = 11, .color = pal.muted, .tabular = true }, "{d} of {d} selected · {s}", .{
                    sel_cnt,
                    rows.len,
                    theme.fmtBytes(c, s.listing.total_bytes),
                });
            } else {
                ui.textf(c, .{ .size = 11, .color = pal.muted, .tabular = true }, "{d} items · {s}", .{
                    rows.len,
                    theme.fmtBytes(c, s.listing.total_bytes),
                });
            }
        }
        if (!compact) {
            ui.text(c, "Cmd+K Quick Open  ·  Space Quick Look", .{ .size = 11, .color = pal.subtle });
        }
    }
}
