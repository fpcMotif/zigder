const nanoui = @import("nanoui");
const AppState = @import("app.zig").AppState;
const commands = @import("commands.zig");
const MenuItem = nanoui.MenuItem;
const MenuClick = nanoui.MenuClick;
const Item = nanoui.menu.Item;

pub const Bundle = struct {
    file: [12]MenuItem = undefined,
    edit: [9]MenuItem = undefined,
    view: [14]MenuItem = undefined,
    go: [7]MenuItem = undefined,
    top: [6]MenuItem = undefined,
};

fn entry(s: *AppState, comptime id: commands.ActionId) MenuItem {
    const spec = comptime commands.specOf(id);
    const CB = struct {
        fn onClick(app: *AppState, _: *Item) void {
            _ = commands.dispatchFromMenu(app, id);
        }
    };
    return .{
        .label = spec.label,
        .accelerator = spec.accel,
        .click = MenuClick.of(s, CB.onClick),
    };
}

pub fn init(b: *Bundle, s: *AppState) void {
    b.file = .{
        entry(s, .new_tab),
        entry(s, .open_new_folder),
        .separator,
        entry(s, .open_selected),
        entry(s, .duplicate),
        entry(s, .begin_rename),
        entry(s, .quick_look),
        .separator,
        entry(s, .trash),
        entry(s, .open_delete_modal),
        .separator,
        entry(s, .close_tab_or_window),
    };
    b.edit = .{
        entry(s, .undo),
        entry(s, .redo),
        .separator,
        .{ .role = .cut },
        entry(s, .copy),
        entry(s, .paste),
        entry(s, .select_all),
        .separator,
        entry(s, .focus_search),
    };
    b.view = .{
        entry(s, .view_icon),
        entry(s, .view_list),
        entry(s, .view_column),
        entry(s, .view_gallery),
        .separator,
        entry(s, .toggle_sidebar),
        entry(s, .toggle_inspector),
        entry(s, .toggle_hidden),
        .separator,
        entry(s, .zoom_in),
        entry(s, .zoom_out),
        entry(s, .reload),
        .separator,
        .{ .role = .toggle_full_screen },
    };
    b.go = .{
        entry(s, .go_back),
        entry(s, .go_forward),
        entry(s, .go_parent),
        .separator,
        entry(s, .open_go_to_folder),
        entry(s, .open_quick_open),
        entry(s, .go_home),
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
