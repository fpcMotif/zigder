const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const app_mod = @import("../app/app.zig");
const AppState = app_mod.AppState;
const ViewMode = app_mod.ViewMode;
const commands = @import("../app/commands.zig");
const theme = @import("theme.zig");
const Palette = theme.Palette;
const volumes = @import("../fs/volumes.zig");
const walk = @import("../index/walk.zig");
const fs_media = @import("../fs/media.zig");
const file_icons = @import("file_icons.zig");

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

pub fn toolbar(
    s: *const AppState,
    c: *ui.Context,
    pal: Palette,
    beside_sidebar: bool,
    search_buf: *ui.TextBuffer,
    q: *commands.Queue,
) void {
    const compact = c.size.w < 740;
    const window_buttons_w: f32 = 86;
    const bar = ui.div(c).row().wFull().h(theme.metric.toolbar_h).itemsCenter().justifyBetween().pl(if (beside_sidebar) 12 else window_buttons_w).pr(12).gap(10).bg(pal.chrome);
    defer bar.end();

    {
        const left = ui.div(c).row().itemsCenter().gap(6).clip();
        defer left.end();
        ui.key(c, "tb-sidebar");
        if (iconBtn(c, "sidebar.left", "Toggle Sidebar", .{
            .size = .sm,
            .selected = s.show_sidebar,
        }).clicked) {
            q.push(.{ .action = .toggle_sidebar });
        }
        {
            const nav = ui.div(c).row().itemsCenter().gap(2);
            defer nav.end();
            ui.key(c, "tb-back");
            if (iconBtn(c, "chevron.left", "Back", .{
                .size = .sm,
                .disabled = !s.tabConst().canBack(),
            }).clicked) {
                q.push(.{ .action = .go_back });
            }
            ui.key(c, "tb-fwd");
            if (iconBtn(c, "chevron.right", "Forward", .{
                .size = .sm,
                .disabled = !s.tabConst().canForward(),
            }).clicked) {
                q.push(.{ .action = .go_forward });
            }
        }
        const cur_name = theme.displayName(s.currentPath());
        const title_wrap = ui.div(c).row().pl(2).clip();
        defer title_wrap.end();
        ui.text(c, cur_name, .{
            .size = theme.size.title,
            .weight = .semibold,
            .color = pal.text,
            .truncate = .ellipsis,
        });
    }

    {
        const right = ui.div(c).row().itemsCenter().gap(8);
        defer right.end();

        {
            const views = ui.div(c).row().itemsCenter().h(28).p(2).gap(1).rounded(7).bg(pal.badge_bg);
            defer views.end();
            const specs = [_]struct { mode: ViewMode, icon: []const u8, lbl: []const u8 }{
                .{ .mode = .icon, .icon = "square.grid.2x2", .lbl = "Icon View" },
                .{ .mode = .list, .icon = "list.bullet", .lbl = "List View" },
                .{ .mode = .column, .icon = "rectangle.split.3x1", .lbl = "Column View" },
                .{ .mode = .gallery, .icon = "squares.below.rectangle", .lbl = "Gallery View" },
            };
            const cap_bg = if (c.theme.dark) pal.row_sel_muted else pal.bg;
            for (specs, 0..) |sp, idx| {
                ui.key(c, c.print("vm-{d}", .{idx}));
                const selected = s.view_mode == sp.mode;
                var seg = ui.div(c).w(28).h(24).center().rounded(5).bg(if (selected) cap_bg else pal.bg.alpha(0)).hover(if (selected) cap_bg else pal.row_hover).control();
                if (selected and !c.theme.dark) {
                    seg = seg.shadow(.{ .color = ui.Color.black.alpha(0.08), .blur = 2, .y = 0.5 });
                }
                const sit = seg.interaction();
                theme.describeNode(c, seg.index, .button, sp.lbl, "", selected, true);
                ui.icon(c, theme.uiIconName(sp.icon), .{
                    .size = 13,
                    .weight = if (selected) .medium else .regular,
                    .color = if (selected) pal.text else pal.muted,
                    .frame = 24,
                });
                seg.end();
                if (sit.clicked) q.push(.{ .set_view_mode = sp.mode });
            }
        }

        const search_w: f32 = if (compact) 136 else 212;
        {
            const sbox = ui.div(c).row().w(search_w).h(28).px(8).gap(5).itemsCenter().rounded(7).bg(pal.bg).border(pal.border).borderW(0.5);
            defer sbox.end();
            ui.icon(c, "magnifyingglass", .{ .size = 12, .color = pal.subtle, .frame = 14 });
            ui.key(c, "tb-search");
            const sres = ui.textField(c, search_buf, .{
                .placeholder = "Search",
                .width = .fill,
                .size = 12.5,
                .bare = true,
                .select_all_on_focus = true,
            });
            if (sres.focused) {
                c.node(sbox.index).style.border = pal.accent;
                c.node(sbox.index).style.border_width = 1.5;
            }
            if (sres.changed) q.push(.inline_search_changed);
            if (sres.submitted and s.search.active()) q.push(.open_active_search_hit);
            if (s.search.active()) {
                ui.key(c, "tb-clear");
                const clr = ui.div(c).w(16).h(16).center().roundedFull().circular().control();
                const cit = clr.interaction();
                theme.describeNode(c, clr.index, .button, "Clear Search", "", false, true);
                ui.icon(c, theme.uiIconName("xmark.circle.fill"), .{
                    .size = 12.5,
                    .color = if (cit.hovered) pal.muted else pal.subtle,
                    .frame = 16,
                });
                clr.end();
                if (cit.clicked) q.push(.clear_inline_search);
            }
        }

        ui.key(c, "tb-inspector");
        if (iconBtn(c, theme.uiIconName("sidebar.right"), "Toggle Inspector", .{
            .size = .sm,
            .selected = s.show_inspector,
        }).clicked) {
            q.push(.{ .action = .toggle_inspector });
        }
    }
}

pub fn tabBar(
    s: *const AppState,
    c: *ui.Context,
    pal: Palette,
    icons: *fs_media.IconCache,
    q: *commands.Queue,
) void {
    const bar = ui.div(c).row().wFull().h(theme.metric.tab_h).itemsCenter().bg(pal.sidebar);
    defer bar.end();

    for (s.tabs.items, 0..) |t, ti| {
        if (ti > 0) theme.vRule(c, pal.divider);
        ui.key(c, c.print("win-tab-{d}", .{ti}));
        const on = ti == s.active_tab;
        const title = theme.displayName(t.path);
        const tab_box = ui.div(c).row().grow().hFull().px(10).gap(6).itemsCenter().bg(if (on) pal.bg else pal.sidebar).hover(if (on) pal.bg else pal.row_hover).control().clip();
        const tit = tab_box.interaction();
        theme.describeNode(c, tab_box.index, .tab, title, t.path, on, true);

        var close_clicked = false;
        if (on) {
            ui.key(c, c.print("win-tab-close-{d}", .{ti}));
            const close_btn = ui.div(c).w(16).h(16).center().rounded(4).hover(pal.row_hover).control();
            const cit = close_btn.interaction();
            theme.describeNode(c, close_btn.index, .button, "Close Tab", "", false, true);
            ui.icon(c, "xmark", .{ .size = 9, .weight = .semibold, .color = if (cit.hovered) pal.text else pal.subtle, .frame = 16 });
            close_btn.end();
            close_clicked = cit.clicked;
        } else {
            ui.div(c).w(16).h(16).end();
        }

        {
            const center = ui.div(c).row().grow().gap(5).center().clip();
            defer center.end();
            file_icons.path(c, icons, t.path, walk.KIND_DIR, 13, theme.iconForPath(t.path, walk.KIND_DIR, pal), null);
            ui.text(c, title, .{
                .size = 12,
                .weight = if (on) .medium else .regular,
                .color = if (on) pal.text else pal.muted,
                .truncate = .ellipsis,
            });
        }
        ui.div(c).w(16).h(16).end();
        tab_box.end();

        if (close_clicked) {
            q.push(.{ .action = .close_tab_or_window });
        } else if (tit.clicked and !on) {
            q.push(.{ .switch_tab = ti });
        }
    }

    theme.vRule(c, pal.divider);
    ui.key(c, "win-tab-add");
    const add_btn = ui.div(c).w(28).hFull().center().hover(pal.row_hover).control();
    const ait = add_btn.interaction();
    theme.describeNode(c, add_btn.index, .button, "New Tab", "", false, true);
    ui.icon(c, "plus", .{ .size = 11, .weight = .medium, .color = pal.muted, .frame = 20 });
    add_btn.end();
    if (ait.clicked) q.push(.{ .action = .new_tab });
}

pub fn sidebar(s: *const AppState, c: *ui.Context, pal: Palette, q: *commands.Queue) void {
    const box = ui.div(c).column().w(212).hFull().pt(theme.metric.toolbar_h).pb(10).px(8).gap(1).bg(pal.sidebar).scrollY().scrollbar(theme.scrollbar(pal));
    defer box.end();

    sectionTitle(c, "Favorites", pal, true);
    for (s.sidebar, 0..) |item, i| {
        if (item.kind != .favorite) continue;
        sidebarRow(s, c, pal, item, i, q);
    }

    sectionTitle(c, "Locations", pal, false);
    for (s.sidebar, 0..) |item, i| {
        if (item.kind != .location) continue;
        sidebarRow(s, c, pal, item, i, q);
    }

    sectionTitle(c, "Tags", pal, false);
    for (s.sidebar, 0..) |item, i| {
        if (item.kind != .tag) continue;
        sidebarTagRow(s, c, pal, item, i, q);
    }
}

fn sectionTitle(c: *ui.Context, title: []const u8, pal: Palette, first: bool) void {
    const h = ui.div(c).row().wFull().px(8).pt(if (first) 4 else 12).pb(3);
    defer h.end();
    ui.text(c, title, .{ .size = theme.size.caption, .weight = .semibold, .color = pal.subtle });
}

fn sidebarRow(
    s: *const AppState,
    c: *ui.Context,
    pal: Palette,
    item: volumes.SidebarItem,
    idx: usize,
    q: *commands.Queue,
) void {
    ui.key(c, c.print("sb-{d}", .{idx}));
    const active = s.active_tag_filter == null and std.mem.eql(u8, s.currentPath(), item.path);
    const row = ui.div(c).row().wFull().h(28).px(8).gap(8).itemsCenter().rounded(7).bg(if (active) pal.row_sel_muted else pal.bg.alpha(0)).hover(if (active) pal.row_sel_muted else pal.row_hover).control();
    const it = row.interaction();
    theme.describeNode(c, row.index, .row, item.label, item.path, active, true);
    defer row.end();
    ui.icon(c, theme.uiIconName(item.icon), .{
        .size = 14.5,
        .weight = .medium,
        .color = pal.accent,
        .frame = 18,
    });
    ui.text(c, item.label, .{
        .size = theme.size.body,
        .weight = if (active) .medium else .regular,
        .color = pal.text,
        .truncate = .ellipsis,
    });
    if (it.clicked) {
        q.push(.{ .navigate_to = item.path });
    }
}

fn sidebarTagRow(
    s: *const AppState,
    c: *ui.Context,
    pal: Palette,
    item: volumes.SidebarItem,
    idx: usize,
    q: *commands.Queue,
) void {
    ui.key(c, c.print("sbt-{d}", .{idx}));
    const active = s.active_tag_filter == item.tag_bit;
    const row = ui.div(c).row().wFull().h(28).px(8).gap(8).itemsCenter().rounded(7).bg(if (active) pal.row_sel_muted else pal.bg.alpha(0)).hover(if (active) pal.row_sel_muted else pal.row_hover).control();
    const it = row.interaction();
    theme.describeNode(c, row.index, .row, item.label, "Tag", active, true);
    defer row.end();
    {
        const slot = ui.div(c).w(18).h(18).center();
        defer slot.end();
        ui.div(c).w(10).h(10).roundedFull().circular().bg(theme.tagColor(item.tag_bit)).end();
    }
    ui.text(c, item.label, .{
        .size = theme.size.body,
        .weight = if (active) .medium else .regular,
        .color = pal.text,
    });
    if (it.clicked) q.push(.{ .set_tag_filter = item.tag_bit });
}

fn bootVolumeFreeBytes(s: *const AppState) u64 {
    for (s.sidebar) |item| {
        if (item.kind == .location and std.mem.eql(u8, item.path, "/")) return item.free_bytes;
    }
    return 0;
}

pub fn bottomBars(
    s: *const AppState,
    c: *ui.Context,
    pal: Palette,
    icons: *fs_media.IconCache,
    q: *commands.Queue,
) void {
    const compact = c.size.w < 740;
    if (s.show_path_bar and !compact) {
        theme.hRule(c, pal.divider);
        const pbar = ui.div(c).row().wFull().h(theme.metric.bar_h).px(10).gap(2).itemsCenter().bg(pal.bg).clip();
        defer pbar.end();

        const cur = s.currentPath();
        const root_btn = ui.div(c).row().px(4).py(2).gap(4).itemsCenter().rounded(4).hover(pal.row_hover).control();
        const rit = root_btn.interaction();
        file_icons.path(c, icons, "/", walk.KIND_DIR, 14, theme.iconForPath("/", walk.KIND_DIR, pal), null);
        ui.text(c, "Macintosh HD", .{ .size = 11.5, .color = if (cur.len <= 1) pal.text else pal.muted });
        root_btn.end();
        if (rit.clicked) q.push(.{ .navigate_to = "/" });

        var acc_end: usize = 0;
        var iter = std.mem.tokenizeScalar(u8, cur, '/');
        var seg_idx: usize = 0;
        while (iter.next()) |comp| {
            acc_end = (@intFromPtr(comp.ptr) - @intFromPtr(cur.ptr)) + comp.len;
            const target_slice = cur[0..acc_end];
            ui.icon(c, "chevron.right", .{ .size = 8.5, .weight = .semibold, .color = pal.subtle });
            ui.key(c, c.print("pb-{d}", .{seg_idx}));
            seg_idx += 1;
            const seg = ui.div(c).row().px(4).py(2).gap(4).itemsCenter().rounded(4).hover(pal.row_hover).control();
            const sit = seg.interaction();
            file_icons.path(c, icons, target_slice, walk.KIND_DIR, 14, theme.iconForPath(target_slice, walk.KIND_DIR, pal), null);
            ui.text(c, comp, .{ .size = 11.5, .color = if (acc_end == cur.len) pal.text else pal.muted });
            seg.end();
            if (sit.clicked and !std.mem.eql(u8, target_slice, cur)) {
                q.push(.{ .navigate_to = target_slice });
            }
        }
    }

    if (s.show_status_bar) {
        theme.hRule(c, pal.divider);
        const sbar = ui.div(c).row().wFull().h(theme.metric.bar_h).px(12).center().bg(pal.chrome);
        defer sbar.end();
        const style: ui.TextStyle = .{ .size = theme.size.caption, .color = pal.muted, .tabular = true };
        if (s.search.active()) {
            const cnt = s.search.results.hits.items.len;
            const st = s.engine.status();
            if (cnt == 0 and st.indexing and !st.ready) {
                ui.text(c, "Indexing…", style);
            } else if (cnt == 1) {
                ui.text(c, "1 item", style);
            } else {
                ui.textf(c, style, "{s} items", .{theme.fmtCount(c, cnt)});
            }
        } else {
            const rows = s.visibleRows();
            const sel_cnt = s.tabConst().selected.count();
            const available = theme.fmtBytes(c, bootVolumeFreeBytes(s));
            if (sel_cnt > 1) {
                ui.textf(c, style, "{s} of {s} selected, {s} available", .{
                    theme.fmtCount(c, sel_cnt),
                    theme.fmtCount(c, rows.len),
                    available,
                });
            } else if (rows.len == 1) {
                ui.textf(c, style, "1 item, {s} available", .{available});
            } else {
                ui.textf(c, style, "{s} items, {s} available", .{ theme.fmtCount(c, rows.len), available });
            }
        }
    }
}
