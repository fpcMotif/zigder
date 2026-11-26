const nanoui = @import("nanoui");
const ui = nanoui.ui;
const AppState = @import("../app/app.zig").AppState;
const app_sel = @import("../app/sel.zig");
const commands = @import("../app/commands.zig");
const theme = @import("theme.zig");
const view_chrome = @import("chrome.zig");
const view_list = @import("list.zig");
const view_column = @import("column.zig");
const view_icon = @import("icon.zig");
const view_gallery = @import("gallery.zig");
const view_inspector = @import("inspector.zig");
const view_overlays = @import("overlays.zig");
const fs_media = @import("../fs/media.zig");

pub fn view(s: *AppState, c: *ui.Context) void {
    syncFrame(s, c);
    var q: commands.Queue = .{};
    renderFrame(s, c, &s.search.buf, &s.overlay.buf, &s.rename.buf, &s.media, &q);
    s.toaster.view(c);
    if (s.media.icons.deferred) s.host.requestRedraw();
    if (q.flush(s)) c.changed = true;
}

fn syncFrame(s: *AppState, c: *ui.Context) void {
    c.title_bar_height = theme.metric.toolbar_h;
    s.media.beginFrame();
    s.text_focused = c.focus_is_text;
    s.syncWithEngine();
    s.inspector.finishLastOpened(s.inspector_path.items);
    if (s.view_mode == .column and s.columns.items.len == 0) {
        app_sel.rebuildColumns(s);
    }
}

fn renderFrame(
    s: *const AppState,
    c: *ui.Context,
    search_buf: *ui.TextBuffer,
    modal_buf: *ui.TextBuffer,
    rename_buf: *ui.TextBuffer,
    media: *fs_media.MediaCache,
    q: *commands.Queue,
) void {
    commands.collectShortcuts(s, c, q);

    const pal = theme.Palette.from(c);
    const compact = c.size.w < 740;
    const show_sb = s.show_sidebar and !compact;
    const show_insp = s.show_inspector and c.size.w >= 860;

    {
        const root = ui.div(c).row().sizeFull().bg(pal.bg);
        defer root.end();

        if (show_sb) {
            view_chrome.sidebar(s, c, pal, q);
            theme.vRule(c, pal.divider);
        }

        const main = ui.div(c).column().grow().hFull().clip();
        defer main.end();

        view_chrome.toolbar(s, c, pal, show_sb, search_buf, q);
        theme.hRule(c, pal.divider);

        if (s.tabs.items.len > 1) {
            view_chrome.tabBar(s, c, pal, &media.icons, q);
            theme.hRule(c, pal.divider);
        }

        {
            const body = ui.div(c).row().grow().wFull().clip();
            defer body.end();

            {
                const center = ui.div(c).column().grow().hFull().clip();
                defer center.end();
                if (s.search.active()) {
                    view_list.renderSearch(s, c, pal, &media.icons, q);
                } else switch (s.view_mode) {
                    .list => view_list.render(s, c, pal, &media.icons, rename_buf, q),
                    .column => view_column.render(s, c, pal, &media.icons, q),
                    .icon => view_icon.render(s, c, pal, &media.icons, q),
                    .gallery => view_gallery.render(s, c, pal, media, show_insp, q),
                }
            }

            if (show_insp) {
                theme.vRule(c, pal.divider);
                view_inspector.render(s, c, pal, media, q);
            }
        }

        view_chrome.bottomBars(s, c, pal, &media.icons, q);
    }

    view_overlays.render(s, c, pal, &media.icons, modal_buf, q);
}
