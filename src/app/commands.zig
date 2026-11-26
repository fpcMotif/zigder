const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const app_mod = @import("app.zig");
const AppState = app_mod.AppState;
const app_ops = @import("ops.zig");
const app_sel = @import("sel.zig");
const session = @import("session.zig");
const fs_entry = @import("../fs/entry.zig");

pub const Guard = enum {
    always,
    no_overlay,
    file_action,
};

pub const ActionId = enum {
    new_tab,
    open_new_folder,
    open_selected,
    duplicate,
    begin_rename,
    quick_look,
    trash,
    open_delete_modal,
    close_tab_or_window,
    undo,
    redo,
    copy,
    paste,
    select_all,
    focus_search,
    view_icon,
    view_list,
    view_column,
    view_gallery,
    toggle_sidebar,
    toggle_inspector,
    toggle_hidden,
    zoom_in,
    zoom_out,
    reload,
    go_back,
    go_forward,
    go_parent,
    open_go_to_folder,
    open_quick_open,
    go_home,
};

pub const Spec = struct {
    id: ActionId,
    label: []const u8,
    accel: []const u8 = "",
    guard: Guard,
};

pub const catalog = [_]Spec{
    .{ .id = .new_tab, .label = "New Tab", .accel = "CmdOrCtrl+T", .guard = .no_overlay },
    .{ .id = .open_new_folder, .label = "New Folder", .accel = "CmdOrCtrl+Shift+N", .guard = .no_overlay },
    .{ .id = .open_selected, .label = "Open", .accel = "CmdOrCtrl+Down", .guard = .file_action },
    .{ .id = .duplicate, .label = "Duplicate", .accel = "CmdOrCtrl+D", .guard = .file_action },
    .{ .id = .begin_rename, .label = "Rename", .accel = "", .guard = .file_action },
    .{ .id = .quick_look, .label = "Quick Look", .accel = "CmdOrCtrl+Y", .guard = .file_action },
    .{ .id = .trash, .label = "Move to Trash", .accel = "CmdOrCtrl+Backspace", .guard = .file_action },
    .{ .id = .open_delete_modal, .label = "Delete Immediately", .accel = "CmdOrCtrl+Alt+Backspace", .guard = .file_action },
    .{ .id = .close_tab_or_window, .label = "Close Tab", .accel = "CmdOrCtrl+W", .guard = .no_overlay },
    .{ .id = .undo, .label = "Undo", .accel = "CmdOrCtrl+Z", .guard = .file_action },
    .{ .id = .redo, .label = "Redo", .accel = "CmdOrCtrl+Shift+Z", .guard = .file_action },
    .{ .id = .copy, .label = "Copy", .accel = "CmdOrCtrl+C", .guard = .file_action },
    .{ .id = .paste, .label = "Paste", .accel = "CmdOrCtrl+V", .guard = .file_action },
    .{ .id = .select_all, .label = "Select All", .accel = "CmdOrCtrl+A", .guard = .file_action },
    .{ .id = .focus_search, .label = "Find", .accel = "CmdOrCtrl+F", .guard = .no_overlay },
    .{ .id = .view_icon, .label = "as Icons", .accel = "CmdOrCtrl+1", .guard = .no_overlay },
    .{ .id = .view_list, .label = "as List", .accel = "CmdOrCtrl+2", .guard = .no_overlay },
    .{ .id = .view_column, .label = "as Columns", .accel = "CmdOrCtrl+3", .guard = .no_overlay },
    .{ .id = .view_gallery, .label = "as Gallery", .accel = "CmdOrCtrl+4", .guard = .no_overlay },
    .{ .id = .toggle_sidebar, .label = "Toggle Sidebar", .accel = "CmdOrCtrl+Alt+S", .guard = .no_overlay },
    .{ .id = .toggle_inspector, .label = "Toggle Inspector", .accel = "CmdOrCtrl+Shift+P", .guard = .no_overlay },
    .{ .id = .toggle_hidden, .label = "Show Hidden Files", .accel = "CmdOrCtrl+Shift+.", .guard = .no_overlay },
    .{ .id = .zoom_in, .label = "Zoom In", .accel = "CmdOrCtrl+=", .guard = .no_overlay },
    .{ .id = .zoom_out, .label = "Zoom Out", .accel = "CmdOrCtrl+-", .guard = .no_overlay },
    .{ .id = .reload, .label = "Reload", .accel = "CmdOrCtrl+R", .guard = .no_overlay },
    .{ .id = .go_back, .label = "Back", .accel = "CmdOrCtrl+[", .guard = .no_overlay },
    .{ .id = .go_forward, .label = "Forward", .accel = "CmdOrCtrl+]", .guard = .no_overlay },
    .{ .id = .go_parent, .label = "Enclosing Folder", .accel = "CmdOrCtrl+Up", .guard = .no_overlay },
    .{ .id = .open_go_to_folder, .label = "Go to Folder…", .accel = "CmdOrCtrl+Shift+G", .guard = .no_overlay },
    .{ .id = .open_quick_open, .label = "Quick Open…", .accel = "CmdOrCtrl+K", .guard = .no_overlay },
    .{ .id = .go_home, .label = "Home", .accel = "CmdOrCtrl+Shift+H", .guard = .no_overlay },
};

pub fn specOf(comptime id: ActionId) Spec {
    for (catalog) |spec| {
        if (spec.id == id) return spec;
    }
    @compileError("missing ActionId in commands.catalog");
}

pub fn guardOfAction(id: ActionId) Guard {
    return switch (id) {
        inline else => |t| comptime specOf(t).guard,
    };
}

pub fn shortcutOf(comptime accel: []const u8) ?ui.Shortcut {
    @setEvalBranchQuota(5000);
    if (accel.len == 0) return null;
    var sc: ui.Shortcut = .{ .key = 0 };
    var parts = std.mem.splitScalar(u8, accel, '+');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "CmdOrCtrl") or std.mem.eql(u8, part, "Cmd")) {
            sc.cmd = true;
        } else if (std.mem.eql(u8, part, "Shift")) {
            sc.shift = true;
        } else if (std.mem.eql(u8, part, "Alt")) {
            sc.alt = true;
        } else if (std.mem.eql(u8, part, "Ctrl")) {
            sc.ctrl = true;
        } else if (std.mem.eql(u8, part, "Up")) {
            sc.key = ui.Shortcut.up;
        } else if (std.mem.eql(u8, part, "Down")) {
            sc.key = ui.Shortcut.down;
        } else if (std.mem.eql(u8, part, "Backspace")) {
            sc.key = ui.Shortcut.backspace;
        } else if (std.mem.eql(u8, part, "Escape")) {
            sc.key = ui.Shortcut.escape;
        } else if (std.mem.eql(u8, part, "Enter")) {
            sc.key = ui.Shortcut.enter;
        } else if (part.len == 1) {
            sc.key = std.ascii.toLower(part[0]);
        } else {
            @compileError("unsupported accelerator token in commands.catalog: " ++ part);
        }
    }
    if (sc.key == 0) @compileError("missing key in accelerator: " ++ accel);
    return sc;
}

pub const SelectRow = struct {
    row: usize,
    toggle_cmd: bool = false,
    range_shift: bool = false,
};

pub const ColumnRow = struct {
    pane: usize,
    row: usize,
};

pub const PathAndName = struct {
    path: []const u8,
    name: []const u8,
};

pub const Command = union(enum) {
    action: ActionId,
    close_overlay,
    cancel_rename,
    commit_rename,
    commit_new_folder,
    confirm_delete,
    modal_move_cursor: isize,
    modal_search_changed,
    modal_commit,
    modal_pick_hit: usize,
    inline_search_changed,
    clear_inline_search,
    open_active_search_hit,
    set_search_scope: session.SearchScope,
    switch_tab: usize,
    set_view_mode: app_mod.ViewMode,
    navigate_to: []const u8,
    navigate_and_select: PathAndName,
    set_tag_filter: ?u3,
    toggle_sort: fs_entry.SortCol,
    select_row: SelectRow,
    activate_row: usize,
    move_cursor: isize,
    select_search_hit: usize,
    open_search_hit: usize,
    select_column_row: ColumnRow,
    select_only_name: []const u8,
    toggle_tag: u3,
    turn_preview_page: i32,
};

pub fn canRun(s: *const AppState, guard: Guard) bool {
    return switch (guard) {
        .always => true,
        .no_overlay => !s.overlay.isOpen(),
        .file_action => s.fileActionsAllowed(),
    };
}

pub fn guardOf(cmd: Command) Guard {
    return switch (cmd) {
        .action => |id| guardOfAction(id),
        .close_overlay,
        .cancel_rename,
        .commit_rename,
        .commit_new_folder,
        .confirm_delete,
        .modal_move_cursor,
        .modal_search_changed,
        .modal_commit,
        .modal_pick_hit,
        .inline_search_changed,
        .clear_inline_search,
        .open_active_search_hit,
        .set_search_scope,
        => .always,
        .move_cursor => .file_action,
        .switch_tab,
        .set_view_mode,
        .navigate_to,
        .navigate_and_select,
        .set_tag_filter,
        .toggle_sort,
        .select_row,
        .activate_row,
        .select_search_hit,
        .open_search_hit,
        .select_column_row,
        .select_only_name,
        .toggle_tag,
        .turn_preview_page,
        => .no_overlay,
    };
}

pub fn dispatch(s: *AppState, cmd: Command) bool {
    if (!canRun(s, guardOf(cmd))) return false;
    switch (cmd) {
        .action => |id| switch (id) {
            .new_tab => s.newTab(),
            .open_new_folder => _ = s.overlay.openNewFolder(),
            .open_selected => if (s.search.active()) s.openSearchHit(s.search.cursor) else s.activateRow(s.tab().cursor),
            .duplicate => app_ops.duplicateSelected(s),
            .begin_rename => app_ops.beginRename(s),
            .quick_look => app_ops.toggleQuickLook(s),
            .trash => app_ops.trashSelected(s),
            .open_delete_modal => app_ops.openDeleteModal(s),
            .close_tab_or_window => {
                if (s.tabs.items.len > 1) {
                    s.closeTab(s.active_tab);
                } else {
                    s.host.requestClose();
                }
            },
            .undo => app_ops.replay(s, true),
            .redo => app_ops.replay(s, false),
            .copy => app_ops.copySelected(s),
            .paste => app_ops.pasteItems(s),
            .select_all => s.selectAll(),
            .focus_search => s.search.buf.focus(),
            .view_icon => s.setViewMode(.icon),
            .view_list => s.setViewMode(.list),
            .view_column => s.setViewMode(.column),
            .view_gallery => s.setViewMode(.gallery),
            .toggle_sidebar => s.show_sidebar = !s.show_sidebar,
            .toggle_inspector => s.show_inspector = !s.show_inspector,
            .toggle_hidden => {
                s.show_hidden = !s.show_hidden;
                app_sel.reload(s) catch {};
            },
            .zoom_in => s.icon_zoom = @min(144, s.icon_zoom + 12),
            .zoom_out => s.icon_zoom = @max(56, s.icon_zoom - 12),
            .reload => app_sel.reload(s) catch {},
            .go_back => s.goBack(),
            .go_forward => s.goForward(),
            .go_parent => s.goParent(),
            .open_go_to_folder => s.openModalSearch(true),
            .open_quick_open => s.openModalSearch(false),
            .go_home => _ = s.navigateOrNotify(s.home),
        },
        .close_overlay => s.closeOverlay(),
        .cancel_rename => s.rename.cancel(),
        .commit_rename => app_ops.commitRename(s),
        .commit_new_folder => {
            if (s.overlay.kind() == .new_folder) {
                app_ops.newFolder(s, s.overlay.buf.text());
                s.closeOverlay();
            }
        },
        .confirm_delete => app_ops.deleteConfirmed(s),
        .modal_move_cursor => |delta| s.overlay.moveCursor(delta),
        .modal_search_changed => s.overlay.updateSearch(s.gpa, s.engine, s.home),
        .modal_commit => s.commitModalGoOrSearch(),
        .modal_pick_hit => |i| {
            if (s.overlay.selectHit(i)) s.commitModalGoOrSearch();
        },
        .inline_search_changed => s.updateInlineSearch(),
        .clear_inline_search => s.clearInlineSearch(),
        .open_active_search_hit => if (s.search.active()) s.openSearchHit(s.search.cursor),
        .set_search_scope => |scope| s.setSearchScope(scope),
        .switch_tab => |idx| s.switchTab(idx),
        .set_view_mode => |mode| s.setViewMode(mode),
        .navigate_to => |path| _ = s.navigateOrNotify(path),
        .navigate_and_select => |target| {
            if (s.navigateOrNotify(target.path)) {
                app_sel.selectOnlyName(s, target.name);
            }
        },
        .set_tag_filter => |bit| s.setTagFilter(bit),
        .toggle_sort => |col| s.toggleSort(col),
        .select_row => |sel| s.selectRow(sel.row, sel.toggle_cmd, sel.range_shift),
        .activate_row => |row| s.activateRow(row),
        .move_cursor => |delta| s.moveCursor(delta),
        .select_search_hit => |i| s.selectSearchHit(i),
        .open_search_hit => |i| s.openSearchHit(i),
        .select_column_row => |cr| {
            if (cr.pane < s.columns.items.len) {
                s.columns.items[cr.pane].selected_row = cr.row;
            }
        },
        .select_only_name => |name| app_sel.selectOnlyName(s, name),
        .toggle_tag => |bit| app_ops.toggleTag(s, bit),
        .turn_preview_page => |delta| _ = s.media.preview.turn(delta),
    }
    return true;
}

pub fn dispatchFromMenu(s: *AppState, id: ActionId) bool {
    if (s.text_focused) {
        const sel_name: ?[:0]const u8 = switch (id) {
            .copy => "copy:",
            .paste => "paste:",
            .select_all => "selectAll:",
            .undo => "undo:",
            .redo => "redo:",
            else => null,
        };
        if (sel_name) |action_sel| {
            s.host.sendEditAction(action_sel);
            return false;
        }
    }
    const ran = dispatch(s, .{ .action = id });
    if (ran) s.host.requestRedraw();
    return ran;
}

pub fn collectShortcuts(s: *const AppState, c: *ui.Context, q: *Queue) void {
    if (s.overlay.isOpen()) {
        if (c.shortcut(.{ .key = ui.Shortcut.escape })) {
            q.push(.close_overlay);
            return;
        }
        if (s.overlay.kind() == .go_or_search) {
            if (c.shortcut(.{ .key = ui.Shortcut.up })) q.push(.{ .modal_move_cursor = -1 });
            if (c.shortcut(.{ .key = ui.Shortcut.down })) q.push(.{ .modal_move_cursor = 1 });
        }
        return;
    }

    if (s.rename.isActive() and c.shortcut(.{ .key = ui.Shortcut.escape })) {
        q.push(.cancel_rename);
        return;
    }

    inline for (catalog) |spec| {
        if (comptime spec.accel.len > 0) {
            const sc = comptime shortcutOf(spec.accel).?;
            if (canRun(s, spec.guard) and c.shortcut(sc)) {
                q.push(.{ .action = spec.id });
            }
        }
    }

    if (canRun(s, .file_action)) {
        if (c.shortcut(.{ .key = ui.Shortcut.up }) or c.input.key == .up) {
            c.input.key = null;
            q.push(.{ .move_cursor = -1 });
        }
        if (c.shortcut(.{ .key = ui.Shortcut.down }) or c.input.key == .down) {
            c.input.key = null;
            q.push(.{ .move_cursor = 1 });
        }
        if (c.focus == 0) {
            if (c.shortcut(.{ .key = ' ' }) or (!c.input.cmd and std.mem.eql(u8, c.input.chars, " "))) {
                c.input.chars = "";
                q.push(.{ .action = .quick_look });
            }
            if (c.shortcut(.{ .key = ui.Shortcut.enter }) or c.input.key == .enter) {
                c.input.key = null;
                q.push(.{ .action = .begin_rename });
            }
        }
    }
}

pub const Queue = struct {
    items: [16]Command = undefined,
    len: usize = 0,
    str_buf: [4096]u8 = undefined,
    str_len: usize = 0,

    fn intern(q: *Queue, text: []const u8) ?[]const u8 {
        const start = q.str_len;
        if (text.len > q.str_buf.len - start) return null;
        const dst = q.str_buf[start..][0..text.len];
        @memcpy(dst, text);
        q.str_len += text.len;
        return dst;
    }

    pub fn push(q: *Queue, cmd: Command) void {
        if (q.len >= q.items.len) return;
        var c = cmd;
        switch (c) {
            .navigate_to, .select_only_name => |*text| text.* = q.intern(text.*) orelse return,
            .navigate_and_select => |*t| {
                const saved = q.str_len;
                t.path = q.intern(t.path) orelse return;
                t.name = q.intern(t.name) orelse {
                    q.str_len = saved;
                    return;
                };
            },
            else => {},
        }
        q.items[q.len] = c;
        q.len += 1;
    }

    pub fn flush(q: *Queue, s: *AppState) bool {
        var any = false;
        for (q.items[0..q.len]) |c| {
            if (dispatch(s, c)) any = true;
        }
        q.len = 0;
        q.str_len = 0;
        return any;
    }
};
