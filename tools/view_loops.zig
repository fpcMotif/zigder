const std = @import("std");

const forbidden = [_][]const u8{
    "activateRow",
    "navigateTo",
    "actionCommitRename",
    "reloadCurrentFolder",
    "openSearchHit",
    "switchTab",
    "closeTab",
    "commitModalGoOrSearch",
    "setTagFilter",
    "goBack",
    "goForward",
    "goParent",
};

fn isForbidden(name: []const u8) bool {
    for (forbidden) |f| {
        if (std.mem.eql(u8, name, f)) return true;
    }
    return false;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const cwd = std.Io.Dir.cwd();

    var dir = try cwd.openDir(io, "zig", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();

    var bad: usize = 0;
    var checked: usize = 0;
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "view_")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        const path = try std.fs.path.join(gpa, &.{ "zig", entry.name });
        defer gpa.free(path);
        bad += try checkFile(io, gpa, path);
        checked += 1;
    }

    if (bad > 0) {
        std.debug.print("{d} mid-loop mutation(s) found inside while(.next()) loops\n", .{bad});
        std.process.exit(1);
    }
    std.debug.print("{d} view files, no mid-loop mutations\n", .{checked});
}

fn checkFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !usize {
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 << 20)) catch return 0;
    defer gpa.free(raw);
    const buf = try gpa.alloc(u8, raw.len + 1);
    defer gpa.free(buf);
    @memcpy(buf[0..raw.len], raw);
    buf[raw.len] = 0;
    const src: [:0]const u8 = buf[0..raw.len :0];

    var toker = std.zig.Tokenizer.init(src);
    var brace_depth: usize = 0;
    var loop_depths: std.ArrayList(usize) = .empty;
    defer loop_depths.deinit(gpa);

    var in_while_cond = false;
    var cond_depth: usize = 0;
    var saw_next = false;
    var pending_loop_brace = false;

    var prev2: std.zig.Token = .{ .tag = .eof, .loc = .{ .start = 0, .end = 0 } };
    var prev1: std.zig.Token = .{ .tag = .eof, .loc = .{ .start = 0, .end = 0 } };
    var bad: usize = 0;

    while (true) {
        const tok = toker.next();
        if (tok.tag == .eof) break;

        if (tok.tag == .keyword_while and !in_while_cond) {
            in_while_cond = true;
            cond_depth = 0;
            saw_next = false;
            pending_loop_brace = false;
        } else if (in_while_cond) {
            if (tok.tag == .l_paren) {
                cond_depth += 1;
            } else if (tok.tag == .r_paren and cond_depth > 0) {
                cond_depth -= 1;
                if (cond_depth == 0) {
                    in_while_cond = false;
                    pending_loop_brace = saw_next;
                }
            } else if (prev1.tag == .period and tok.tag == .identifier) {
                const name = src[tok.loc.start..tok.loc.end];
                if (std.mem.eql(u8, name, "next")) saw_next = true;
            }
        }

        if (tok.tag == .l_brace) {
            brace_depth += 1;
            if (pending_loop_brace) {
                try loop_depths.append(gpa, brace_depth);
                pending_loop_brace = false;
            }
        } else if (tok.tag == .r_brace) {
            if (brace_depth > 0) brace_depth -= 1;
            while (loop_depths.items.len > 0 and loop_depths.items[loop_depths.items.len - 1] > brace_depth) {
                _ = loop_depths.pop();
            }
        } else if (tok.tag == .semicolon and pending_loop_brace) {
            pending_loop_brace = false;
        }

        if (loop_depths.items.len > 0 and prev2.tag == .period and prev1.tag == .identifier and tok.tag == .l_paren) {
            const name = src[prev1.loc.start..prev1.loc.end];
            if (isForbidden(name)) {
                const line = 1 + std.mem.count(u8, src[0..prev1.loc.start], "\n");
                std.debug.print("{s}:{d}: mid-loop mutation '{s}' inside while(.next())\n", .{ path, line, name });
                bad += 1;
            }
        }

        prev2 = prev1;
        prev1 = tok;
    }

    return bad;
}
