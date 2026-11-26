const std = @import("std");
const index_read = @import("read.zig");

extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn dlopen(path: [*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;
extern "c" fn CFStringCreateWithBytes(alloc: ?*anyopaque, bytes: [*]const u8, numBytes: isize, encoding: u32, isExternal: u8) ?*anyopaque;
extern "c" fn CFRelease(cf: *anyopaque) void;

const O_RDONLY: c_int = 0;
const RTLD_LAZY: c_int = 1;
const kCFStringEncodingUTF8: u32 = 0x08000100;

fn hasFullDiskAccess(home: []const u8) bool {
    const sys_fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY);
    if (sys_fd >= 0) {
        _ = close(sys_fd);
        return true;
    }
    var buf: [1024]u8 = undefined;
    const p = std.fmt.bufPrintSentinel(&buf, "{s}/Library/Application Support/com.apple.TCC/TCC.db", .{home}, 0) catch return false;
    const user_fd = open(p, O_RDONLY);
    if (user_fd >= 0) {
        _ = close(user_fd);
        return true;
    }
    return false;
}

const PreflightFn = *const fn (*anyopaque, ?*anyopaque) callconv(.c) c_int;
var preflight_loaded: std.atomic.Value(u8) = .init(0);
var preflight_fn: ?PreflightFn = null;

fn tccPreflight(service: []const u8) bool {
    if (preflight_loaded.load(.acquire) == 0) {
        const handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_LAZY);
        if (handle) |h| {
            if (dlsym(h, "TCCAccessPreflight")) |sym| {
                preflight_fn = @ptrCast(@alignCast(sym));
            }
        }
        preflight_loaded.store(1, .release);
    }
    const f = preflight_fn orelse return false;
    const cf = CFStringCreateWithBytes(null, service.ptr, @intCast(service.len), kCFStringEncodingUTF8, 0) orelse return false;
    defer CFRelease(cf);
    return f(cf, null) == 0;
}

const gated_in_home = [_][]const u8{
    "Desktop",
    "Documents",
    "Downloads",
    "Library/Mobile Documents",
    "Library/Containers",
    "Library/Group Containers",
    "Library/CloudStorage",
    "Pictures/Photos Library.photoslibrary",
};

pub fn gatedPaths(gpa: std.mem.Allocator, home: []const u8) ![][]u8 {
    if (hasFullDiskAccess(home)) {
        const out = try gpa.alloc([]u8, 1);
        out[0] = try gpa.dupe(u8, "/Volumes");
        return out;
    }
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |p| gpa.free(p);
        out.deinit(gpa);
    }
    const clean_home = std.mem.trimEnd(u8, home, "/");
    for (gated_in_home) |sub| {
        const allow = if (std.mem.eql(u8, sub, "Desktop"))
            tccPreflight("kTCCServiceSystemPolicyDesktopFolder")
        else if (std.mem.eql(u8, sub, "Documents"))
            tccPreflight("kTCCServiceSystemPolicyDocumentsFolder")
        else if (std.mem.eql(u8, sub, "Downloads"))
            tccPreflight("kTCCServiceSystemPolicyDownloadsFolder")
        else
            false;
        if (!allow) {
            const p = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ clean_home, sub });
            try out.append(gpa, p);
        }
    }
    try out.append(gpa, try gpa.dupe(u8, "/Volumes"));
    return try out.toOwnedSlice(gpa);
}

pub fn isBlocked(path: []const u8, skip_paths: []const []const u8) bool {
    for (skip_paths) |s| {
        if (index_read.hasPathPrefix(path, s)) return true;
    }
    return false;
}
