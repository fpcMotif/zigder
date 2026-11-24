const nanoui = @import("nanoui");
const ui = nanoui.ui;
const AppState = @import("app.zig").AppState;
const app_sel = @import("app_sel.zig");
const theme = @import("theme.zig");
const view_chrome = @import("view_chrome.zig");
const view_list = @import("view_list.zig");
const view_column = @import("view_column.zig");
const view_icon = @import("view_icon.zig");
const view_gallery = @import("view_gallery.zig");
const view_inspector = @import("view_inspector.zig");
const view_overlays = @import("view_overlays.zig");
const file_icons = @import("file_icons.zig");

pub fn view(s: *AppState, c: *ui.Context) void {
    c.title_bar_height = theme.metric.toolbar_h;
    file_icons.beginFrame();

    s.text_focused = c.focus_is_text;
    const gen = s.engine.generation.load(.acquire);
    if (gen != s.seen_gen) {
        s.seen_gen = gen;
        app_sel.onIndexChanged(s);
    }

    handleShortcuts(s, c);

    const pal = theme.Palette.from(c);
    const compact = c.size.w < 740;
    const show_sb = s.show_sidebar and !compact;
    const show_insp = s.show_inspector and c.size.w >= 880;

    {
        const root = ui.div(c).row().sizeFull().bg(pal.bg);
        defer root.end();

        if (show_sb) view_chrome.sidebar(s, c, pal);

        const main = ui.div(c).column().grow().hFull().clip();
        defer main.end();

        view_chrome.toolbar(s, c, pal, show_sb);

        {
            const body = ui.div(c).row().grow().wFull().clip();
            defer body.end();

            {
                const center = ui.div(c).column().grow().hFull().clip();
                defer center.end();
                if (s.isSearchActive()) {
                    view_list.renderSearch(s, c, pal);
                } else switch (s.view_mode) {
                    .list => view_list.render(s, c, pal),
                    .column => view_column.render(s, c, pal),
                    .icon => view_icon.render(s, c, pal),
                    .gallery => view_gallery.render(s, c, pal),
                }
            }

            if (show_insp) view_inspector.render(s, c, pal);
        }

        view_chrome.bottomBars(s, c, pal);
    }

    view_overlays.render(s, c, pal);
    s.toaster.view(c);
}

fn handleShortcuts(s: *AppState, c: *ui.Context) void {
    if (s.overlay != .none) {
        if (c.shortcut(.{ .key = ui.Shortcut.escape })) {
            s.closeOverlay();
            return;
        }
        if (s.overlay == .go_or_search) {
            if (c.shortcut(.{ .key = ui.Shortcut.up }) and s.modal_cursor > 0) {
                s.modal_cursor -= 1;
            }
            if (c.shortcut(.{ .key = ui.Shortcut.down }) and s.modal_cursor + 1 < s.modal_results.hits.items.len) {
                s.modal_cursor += 1;
            }
        }
        return;
    }

    if (s.renaming_row != null and c.shortcut(.{ .key = ui.Shortcut.escape })) {
        s.renaming_row = null;
        return;
    }

    if (c.shortcut(.{ .key = 'f', .cmd = true })) s.search_buf.focus();
    if (c.shortcut(.{ .key = 'k', .cmd = true })) s.openModalSearch(false);
    if (c.shortcut(.{ .key = 'g', .cmd = true, .shift = true })) s.openModalSearch(true);
    if (c.shortcut(.{ .key = 'n', .cmd = true, .shift = true })) s.openNewFolderModal();
    if (c.shortcut(.{ .key = 't', .cmd = true })) s.newTab();
    if (c.shortcut(.{ .key = 'w', .cmd = true }) and s.tabs.items.len > 1) s.closeTab(s.active_tab);
    if (c.shortcut(.{ .key = '1', .cmd = true })) s.setViewMode(.icon);
    if (c.shortcut(.{ .key = '2', .cmd = true })) s.setViewMode(.list);
    if (c.shortcut(.{ .key = '3', .cmd = true })) s.setViewMode(.column);
    if (c.shortcut(.{ .key = '4', .cmd = true })) s.setViewMode(.gallery);
    if (c.shortcut(.{ .key = 's', .cmd = true, .alt = true })) s.show_sidebar = !s.show_sidebar;
    if (c.shortcut(.{ .key = 'p', .cmd = true, .shift = true })) s.show_inspector = !s.show_inspector;
    if (c.shortcut(.{ .key = '.', .cmd = true, .shift = true })) {
        s.show_hidden = !s.show_hidden;
        s.reloadCurrentFolder() catch {};
    }
    if (c.shortcut(.{ .key = '[', .cmd = true })) s.goBack();
    if (c.shortcut(.{ .key = ']', .cmd = true })) s.goForward();
    if (c.shortcut(.{ .key = ui.Shortcut.up, .cmd = true })) s.goParent();
    if (c.shortcut(.{ .key = '=', .cmd = true })) s.icon_zoom = @min(144, s.icon_zoom + 12);
    if (c.shortcut(.{ .key = '-', .cmd = true })) s.icon_zoom = @max(56, s.icon_zoom - 12);
    if (c.shortcut(.{ .key = 'r', .cmd = true })) s.reloadCurrentFolder() catch {};

    if (!c.focus_is_text) {
        if (c.shortcut(.{ .key = 'd', .cmd = true })) s.actionDuplicate();
        if (c.shortcut(.{ .key = 'y', .cmd = true })) s.actionQuickLook();
        if (c.shortcut(.{ .key = ui.Shortcut.backspace, .cmd = true, .alt = true })) s.openDeleteModal();
        if (c.shortcut(.{ .key = ui.Shortcut.backspace, .cmd = true })) s.actionTrash();
        if (c.shortcut(.{ .key = ui.Shortcut.down, .cmd = true })) {
            if (s.isSearchActive()) s.openSearchHit(s.search_cursor) else s.activateRow(s.tab().cursor);
        }
        if (c.shortcut(.{ .key = 'z', .cmd = true, .shift = true })) s.actionRedo();
        if (c.shortcut(.{ .key = 'z', .cmd = true })) s.actionUndo();
        if (c.shortcut(.{ .key = 'c', .cmd = true })) s.actionCopy();
        if (c.shortcut(.{ .key = 'v', .cmd = true })) s.actionPaste();
        if (c.shortcut(.{ .key = 'a', .cmd = true })) {
            const rows = s.visibleRows();
            s.tab().selected.clearRetainingCapacity();
            for (rows) |eid| s.tab().selected.put(s.gpa, eid, {}) catch {};
        }
        if (c.shortcut(.{ .key = ui.Shortcut.up }) or c.input.key == .up) {
            c.input.key = null;
            s.moveCursor(-1);
        }
        if (c.shortcut(.{ .key = ui.Shortcut.down }) or c.input.key == .down) {
            c.input.key = null;
            s.moveCursor(1);
        }
        if (c.focus == 0) {
            if (c.shortcut(.{ .key = ' ' }) or (!c.input.cmd and std.mem.eql(u8, c.input.chars, " "))) {
                c.input.chars = "";
                s.actionQuickLook();
            }
            if (c.shortcut(.{ .key = ui.Shortcut.enter }) or c.input.key == .enter) {
                c.input.key = null;
                s.actionBeginRename();
            }
        }
    }
}

const std = @import("std");
