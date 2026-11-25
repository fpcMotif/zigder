const std = @import("std");
const walk = @import("../index/walk.zig");

pub const PreviewKind = enum { pdf, image };

pub const Category = enum {
    alias,
    folder,
    app,
    package,
    image,
    audio,
    code,
    shell,
    text_doc,
    archive,
    document,
};

pub const Info = struct {
    label: []const u8,
    category: Category,
    preview: ?PreviewKind = null,
};

const package_exts = [_][]const u8{
    ".app",
    ".bundle",
    ".framework",
    ".plugin",
    ".appex",
    ".kext",
    ".xpc",
    ".photoslibrary",
    ".musiclibrary",
    ".tvlibrary",
    ".imovielibrary",
    ".rtfd",
    ".xcodeproj",
    ".xcworkspace",
    ".playground",
    ".fcpbundle",
};

pub fn isAppName(name: []const u8) bool {
    return name.len > 4 and std.ascii.eqlIgnoreCase(name[name.len - 4 ..], ".app");
}

pub fn isPackageName(name: []const u8) bool {
    for (package_exts) |ext| {
        if (name.len > ext.len and std.ascii.eqlIgnoreCase(name[name.len - ext.len ..], ext)) return true;
    }
    return false;
}

pub fn isContainerKind(kind_byte: u8) bool {
    return (kind_byte & 3) != walk.KIND_FILE;
}

pub fn extOfName(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    if (dot == 0 or dot + 1 >= name.len) return "";
    return name[dot + 1 ..];
}

fn extIn(ext: []const u8, list: []const []const u8) bool {
    for (list) |item| {
        if (std.ascii.eqlIgnoreCase(ext, item)) return true;
    }
    return false;
}

pub fn classifyExt(ext: []const u8) Info {
    if (ext.len == 0) return .{ .label = "Document", .category = .document };
    if (std.ascii.eqlIgnoreCase(ext, "png")) return .{ .label = "PNG Image", .category = .image, .preview = .image };
    if (extIn(ext, &.{ "jpg", "jpeg" })) return .{ .label = "JPEG Image", .category = .image, .preview = .image };
    if (extIn(ext, &.{ "gif", "webp", "heic", "tiff", "tif", "bmp" })) return .{ .label = "Image", .category = .image, .preview = .image };
    if (std.ascii.eqlIgnoreCase(ext, "svg")) return .{ .label = "Image", .category = .image, .preview = null };
    if (std.ascii.eqlIgnoreCase(ext, "pdf")) return .{ .label = "PDF Document", .category = .text_doc, .preview = .pdf };
    if (std.ascii.eqlIgnoreCase(ext, "zig")) return .{ .label = "Zig Source", .category = .code };
    if (std.ascii.eqlIgnoreCase(ext, "rs")) return .{ .label = "Rust Source", .category = .code };
    if (std.ascii.eqlIgnoreCase(ext, "json")) return .{ .label = "JSON", .category = .code };
    if (std.ascii.eqlIgnoreCase(ext, "toml")) return .{ .label = "TOML", .category = .code };
    if (extIn(ext, &.{ "c", "h", "cpp", "hpp", "swift", "go", "py", "ts", "tsx", "js", "jsx", "yaml", "yml", "nix" })) {
        return .{ .label = "Document", .category = .code };
    }
    if (std.ascii.eqlIgnoreCase(ext, "md")) return .{ .label = "Markdown", .category = .text_doc };
    if (std.ascii.eqlIgnoreCase(ext, "txt")) return .{ .label = "Plain Text", .category = .text_doc };
    if (extIn(ext, &.{ "doc", "docx" })) return .{ .label = "Word Document", .category = .text_doc };
    if (std.ascii.eqlIgnoreCase(ext, "rtf")) return .{ .label = "Document", .category = .text_doc };
    if (extIn(ext, &.{ "sh", "zsh", "bash" })) return .{ .label = "Document", .category = .shell };
    if (extIn(ext, &.{ "mp3", "m4a", "wav", "flac", "aac", "ogg", "opus" })) return .{ .label = "Document", .category = .audio };
    if (extIn(ext, &.{ "zip", "tar", "gz", "tgz", "dmg", "7z", "xz", "zst" })) return .{ .label = "Document", .category = .archive };
    return .{ .label = "Document", .category = .document };
}

pub fn classifyParts(kind_byte: u8, is_app: bool, is_pkg: bool, ext: []const u8) Info {
    const base = kind_byte & 3;
    if (base == walk.KIND_LINK) return .{ .label = "Alias", .category = .alias };
    if (base == walk.KIND_DIR) {
        if (is_app) return .{ .label = "Application", .category = .app };
        if (is_pkg) return .{ .label = "Package", .category = .package };
        return .{ .label = "Folder", .category = .folder };
    }
    return classifyExt(ext);
}

pub fn classify(name: []const u8, kind_byte: u8) Info {
    const is_dir = (kind_byte & 3) == walk.KIND_DIR;
    return classifyParts(kind_byte, is_dir and isAppName(name), is_dir and isPackageName(name), extOfName(name));
}
