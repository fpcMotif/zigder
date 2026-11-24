const nanoui = @import("nanoui");
const AppState = @import("app.zig").AppState;
const MenuItem = nanoui.MenuItem;
const MenuClick = nanoui.MenuClick;
const Item = nanoui.menu.Item;

pub const Bundle = struct {
    file: [11]MenuItem = undefined,
    edit: [8]MenuItem = undefined,
    view: [10]MenuItem = undefined,
    go: [7]MenuItem = undefined,
    top: [6]MenuItem = undefined,
};

pub fn init(b: *Bundle, s: *AppState) void {
    b.file = .{
        .{ .label = "New Tab", .accelerator = "CmdOrCtrl+T", .click = MenuClick.of(s, onNewTab) },
        .{ .label = "New Folder", .accelerator = "CmdOrCtrl+Shift+N", .click = MenuClick.of(s, onNewFolder) },
        .separator,
        .{ .label = "Duplicate", .accelerator = "CmdOrCtrl+D", .click = MenuClick.of(s, onDuplicate) },
        .{ .label = "Rename", .click = MenuClick.of(s, onRename) },
        .{ .label = "Quick Look", .accelerator = "CmdOrCtrl+Y", .click = MenuClick.of(s, onQuickLook) },
        .separator,
        .{ .label = "Move to Trash", .accelerator = "CmdOrCtrl+Backspace", .click = MenuClick.of(s, onTrash) },
        .{ .label = "Delete Immediately", .accelerator = "CmdOrCtrl+Alt+Backspace", .click = MenuClick.of(s, onDelete) },
        .separator,
        .{ .role = .close },
    };
    b.edit = .{
        .{ .label = "Undo", .accelerator = "CmdOrCtrl+Z", .click = MenuClick.of(s, onUndo) },
        .{ .label = "Redo", .accelerator = "CmdOrCtrl+Shift+Z", .click = MenuClick.of(s, onRedo) },
        .separator,
        .{ .label = "Copy", .accelerator = "CmdOrCtrl+C", .click = MenuClick.of(s, onCopy) },
        .{ .label = "Paste", .accelerator = "CmdOrCtrl+V", .click = MenuClick.of(s, onPaste) },
        .{ .label = "Select All", .accelerator = "CmdOrCtrl+A", .click = MenuClick.of(s, onSelectAll) },
        .separator,
        .{ .label = "Find", .accelerator = "CmdOrCtrl+F", .click = MenuClick.of(s, onFind) },
    };
    b.view = .{
        .{ .label = "as Icons", .accelerator = "CmdOrCtrl+1", .click = MenuClick.of(s, onViewIcons) },
        .{ .label = "as List", .accelerator = "CmdOrCtrl+2", .click = MenuClick.of(s, onViewList) },
        .{ .label = "as Columns", .accelerator = "CmdOrCtrl+3", .click = MenuClick.of(s, onViewColumns) },
        .{ .label = "as Gallery", .accelerator = "CmdOrCtrl+4", .click = MenuClick.of(s, onViewGallery) },
        .separator,
        .{ .label = "Toggle Sidebar", .accelerator = "CmdOrCtrl+Alt+S", .click = MenuClick.of(s, onToggleSidebar) },
        .{ .label = "Toggle Inspector", .accelerator = "CmdOrCtrl+Shift+P", .click = MenuClick.of(s, onToggleInspector) },
        .{ .label = "Show Hidden Files", .accelerator = "CmdOrCtrl+Shift+.", .click = MenuClick.of(s, onToggleHidden) },
        .separator,
        .{ .role = .toggle_full_screen },
    };
    b.go = .{
        .{ .label = "Back", .accelerator = "CmdOrCtrl+[", .click = MenuClick.of(s, onBack) },
        .{ .label = "Forward", .accelerator = "CmdOrCtrl+]", .click = MenuClick.of(s, onForward) },
        .{ .label = "Enclosing Folder", .accelerator = "CmdOrCtrl+Up", .click = MenuClick.of(s, onParent) },
        .separator,
        .{ .label = "Go to Folder...", .accelerator = "CmdOrCtrl+Shift+G", .click = MenuClick.of(s, onGoToFolder) },
        .{ .label = "Quick Open...", .accelerator = "CmdOrCtrl+K", .click = MenuClick.of(s, onQuickOpen) },
        .{ .label = "Home", .accelerator = "CmdOrCtrl+Shift+H", .click = MenuClick.of(s, onHome) },
    };
    b.top = .{
        .{ .role = .app_menu },
        .{ .label = "File", .submenu = &b.file },
        .{ .label = "Edit", .submenu = &b.edit },
        .{ .label = "View", .submenu = &b.view },
        .{ .label = "Go", .submenu = &b.go },
        .{ .role = .window_menu },
    };
}

fn onNewTab(s: *AppState, _: *Item) void {
    s.newTab();
}
fn onNewFolder(s: *AppState, _: *Item) void {
    s.openNewFolderModal();
}
fn onDuplicate(s: *AppState, _: *Item) void {
    s.actionDuplicate();
}
fn onRename(s: *AppState, _: *Item) void {
    s.actionBeginRename();
}
fn onQuickLook(s: *AppState, _: *Item) void {
    s.actionQuickLook();
}
fn onTrash(s: *AppState, _: *Item) void {
    s.actionTrash();
}
fn onDelete(s: *AppState, _: *Item) void {
    s.openDeleteModal();
}
fn onUndo(s: *AppState, _: *Item) void {
    s.actionUndo();
}
fn onRedo(s: *AppState, _: *Item) void {
    s.actionRedo();
}
fn onCopy(s: *AppState, _: *Item) void {
    s.actionCopy();
}
fn onPaste(s: *AppState, _: *Item) void {
    s.actionPaste();
}
fn onSelectAll(s: *AppState, _: *Item) void {
    const rows = s.visibleRows();
    s.tab().selected.clearRetainingCapacity();
    for (rows) |eid| s.tab().selected.put(s.gpa, eid, {}) catch {};
}
fn onFind(s: *AppState, _: *Item) void {
    s.search_buf.focus();
}
fn onViewIcons(s: *AppState, _: *Item) void {
    s.setViewMode(.icon);
}
fn onViewList(s: *AppState, _: *Item) void {
    s.setViewMode(.list);
}
fn onViewColumns(s: *AppState, _: *Item) void {
    s.setViewMode(.column);
}
fn onViewGallery(s: *AppState, _: *Item) void {
    s.setViewMode(.gallery);
}
fn onToggleSidebar(s: *AppState, _: *Item) void {
    s.show_sidebar = !s.show_sidebar;
}
fn onToggleInspector(s: *AppState, _: *Item) void {
    s.show_inspector = !s.show_inspector;
}
fn onToggleHidden(s: *AppState, _: *Item) void {
    s.show_hidden = !s.show_hidden;
    s.reloadCurrentFolder() catch {};
}
fn onBack(s: *AppState, _: *Item) void {
    s.goBack();
}
fn onForward(s: *AppState, _: *Item) void {
    s.goForward();
}
fn onParent(s: *AppState, _: *Item) void {
    s.goParent();
}
fn onGoToFolder(s: *AppState, _: *Item) void {
    s.openModalSearch(true);
}
fn onQuickOpen(s: *AppState, _: *Item) void {
    s.openModalSearch(false);
}
fn onHome(s: *AppState, _: *Item) void {
    s.navigateTo(s.home, true) catch {};
}
