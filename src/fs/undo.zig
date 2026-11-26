const std = @import("std");
const fs_ops = @import("ops.zig");
const index_read = @import("../index/read.zig");

pub const PathPair = struct {
    from: []u8,
    to: []u8,
};

pub const TrashStep = struct {
    from: []u8,
    trashed: ?[]u8,
};

pub const UndoStep = union(enum) {
    move: PathPair,
    copy: PathPair,
    rename: PathPair,
    create_dir: []u8,
    create_file: []u8,
    trash: TrashStep,

    pub fn deinit(step: UndoStep, gpa: std.mem.Allocator) void {
        switch (step) {
            .move, .copy, .rename => |p| {
                gpa.free(p.from);
                gpa.free(p.to);
            },
            .create_dir, .create_file => |p| gpa.free(p),
            .trash => |t| {
                gpa.free(t.from);
                if (t.trashed) |tr| gpa.free(tr);
            },
        }
    }
};

pub const UndoStatus = enum {
    empty,
    ok,
    partial,
    failed,
};

pub const BatchOutcome = struct {
    succeeded: usize = 0,
    failed: usize = 0,
    touched_dirs: [][]u8 = &.{},

    pub fn deinit(o: *BatchOutcome, gpa: std.mem.Allocator) void {
        if (o.touched_dirs.len > 0) index_read.freePaths(gpa, o.touched_dirs);
        o.* = .{};
    }
};

pub const UndoOutcome = struct {
    status: UndoStatus = .empty,
    succeeded: usize = 0,
    failed: usize = 0,
    first_err: ?anyerror = null,
    touched_dirs: [][]u8 = &.{},

    pub fn deinit(o: *UndoOutcome, gpa: std.mem.Allocator) void {
        if (o.touched_dirs.len > 0) index_read.freePaths(gpa, o.touched_dirs);
        o.* = .{};
    }
};

fn freeStepList(gpa: std.mem.Allocator, list: []UndoStep) void {
    for (list) |st| st.deinit(gpa);
    gpa.free(list);
}

fn trashedOrNull(gpa: std.mem.Allocator, raw: []u8) ?[]u8 {
    if (raw.len > 0) return raw;
    gpa.free(raw);
    return null;
}

fn appendUniqueDir(gpa: std.mem.Allocator, dirs: *std.ArrayList([]u8), path: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse "/";
    for (dirs.items) |existing| {
        if (std.mem.eql(u8, existing, dir)) return;
    }
    try dirs.append(gpa, try gpa.dupe(u8, dir));
}

fn freeDirList(gpa: std.mem.Allocator, dirs: *std.ArrayList([]u8)) void {
    for (dirs.items) |d| gpa.free(d);
    dirs.deinit(gpa);
}

fn recordStepDirs(gpa: std.mem.Allocator, dirs: *std.ArrayList([]u8), step: UndoStep) void {
    switch (step) {
        .move, .rename => |p| {
            appendUniqueDir(gpa, dirs, p.from) catch {};
            appendUniqueDir(gpa, dirs, p.to) catch {};
        },
        .copy => |p| appendUniqueDir(gpa, dirs, p.to) catch {},
        .create_dir, .create_file => |p| appendUniqueDir(gpa, dirs, p) catch {},
        .trash => |t| {
            appendUniqueDir(gpa, dirs, t.from) catch {};
            if (t.trashed) |tr| appendUniqueDir(gpa, dirs, tr) catch {};
        },
    }
}

fn applyUndoStep(gpa: std.mem.Allocator, step: UndoStep) !void {
    switch (step) {
        .move, .rename => |p| try fs_ops.moveToExactPath(gpa, p.to, p.from),
        .copy => |p| try fs_ops.deleteImmediately(gpa, p.to),
        .create_dir => |p| try fs_ops.removeCreated(gpa, p, true),
        .create_file => |p| try fs_ops.removeCreated(gpa, p, false),
        .trash => |t| {
            const tr = t.trashed orelse return error.CannotPutBack;
            try fs_ops.moveToExactPath(gpa, tr, t.from);
        },
    }
}

fn applyRedoStep(gpa: std.mem.Allocator, step: *UndoStep) !void {
    switch (step.*) {
        .move, .rename => |p| try fs_ops.moveToExactPath(gpa, p.from, p.to),
        .copy => |p| try fs_ops.copyToExactPath(gpa, p.from, p.to),
        .create_dir => |p| try fs_ops.createExactDir(gpa, p),
        .create_file => |p| try fs_ops.createExactFile(gpa, p),
        .trash => |*t| {
            const raw = try fs_ops.trashItem(gpa, t.from);
            if (t.trashed) |old| gpa.free(old);
            t.trashed = trashedOrNull(gpa, raw);
        },
    }
}

pub const max_undo = 64;

pub const UndoStack = struct {
    undo_list: std.ArrayList([]UndoStep) = .empty,
    redo_list: std.ArrayList([]UndoStep) = .empty,

    pub fn deinit(u: *UndoStack, gpa: std.mem.Allocator) void {
        for (u.undo_list.items) |b| freeStepList(gpa, b);
        u.undo_list.deinit(gpa);
        u.clearRedo(gpa);
        u.redo_list.deinit(gpa);
    }

    fn clearRedo(u: *UndoStack, gpa: std.mem.Allocator) void {
        for (u.redo_list.items) |b| freeStepList(gpa, b);
        u.redo_list.clearRetainingCapacity();
    }

    fn pushBatch(list: *std.ArrayList([]UndoStep), gpa: std.mem.Allocator, steps: []UndoStep) !void {
        errdefer freeStepList(gpa, steps);
        if (list.items.len >= max_undo) {
            freeStepList(gpa, list.items[0]);
            _ = list.orderedRemove(0);
        }
        try list.append(gpa, steps);
    }

    fn pushSingle(u: *UndoStack, gpa: std.mem.Allocator, step: UndoStep) !void {
        errdefer step.deinit(gpa);
        const steps = try gpa.alloc(UndoStep, 1);
        steps[0] = step;
        u.clearRedo(gpa);
        try pushBatch(&u.undo_list, gpa, steps);
    }

    pub fn createFolder(u: *UndoStack, gpa: std.mem.Allocator, dir: []const u8, base_name: []const u8) ![]u8 {
        const created = try fs_ops.createFolder(gpa, dir, base_name);
        errdefer gpa.free(created);
        const copy = try gpa.dupe(u8, created);
        u.pushSingle(gpa, .{ .create_dir = copy }) catch {};
        return created;
    }

    pub fn createFile(u: *UndoStack, gpa: std.mem.Allocator, dir: []const u8, base_name: []const u8) ![]u8 {
        const created = try fs_ops.createFile(gpa, dir, base_name);
        errdefer gpa.free(created);
        const copy = try gpa.dupe(u8, created);
        u.pushSingle(gpa, .{ .create_file = copy }) catch {};
        return created;
    }

    pub fn renameItem(u: *UndoStack, gpa: std.mem.Allocator, path: []const u8, new_name: []const u8) ![]u8 {
        const dst = try fs_ops.renameItem(gpa, path, new_name);
        if (!std.mem.eql(u8, path, dst)) {
            const from_c = gpa.dupe(u8, path) catch return dst;
            errdefer gpa.free(from_c);
            const to_c = gpa.dupe(u8, dst) catch {
                gpa.free(from_c);
                return dst;
            };
            u.pushSingle(gpa, .{ .rename = .{ .from = from_c, .to = to_c } }) catch {};
        }
        return dst;
    }

    const BatchOp = union(enum) {
        dup,
        paste: []const u8,
        trash,
    };

    pub fn duplicateBatch(u: *UndoStack, gpa: std.mem.Allocator, paths: []const []const u8) !BatchOutcome {
        return u.runBatch(gpa, paths, .dup);
    }

    pub fn pasteBatch(u: *UndoStack, gpa: std.mem.Allocator, src_paths: []const []const u8, dst_dir: []const u8) !BatchOutcome {
        return u.runBatch(gpa, src_paths, .{ .paste = dst_dir });
    }

    pub fn trashBatch(u: *UndoStack, gpa: std.mem.Allocator, paths: []const []const u8) !BatchOutcome {
        return u.runBatch(gpa, paths, .trash);
    }

    fn runBatch(u: *UndoStack, gpa: std.mem.Allocator, paths: []const []const u8, op: BatchOp) !BatchOutcome {
        var steps: std.ArrayList(UndoStep) = .empty;
        errdefer {
            for (steps.items) |st| st.deinit(gpa);
            steps.deinit(gpa);
        }
        var touched: std.ArrayList([]u8) = .empty;
        errdefer freeDirList(gpa, &touched);
        var failed: usize = 0;

        for (paths) |src| {
            const raw = switch (op) {
                .dup => fs_ops.duplicateItem(gpa, src),
                .paste => |d| fs_ops.copyItem(gpa, src, d),
                .trash => fs_ops.trashItem(gpa, src),
            } catch {
                failed += 1;
                continue;
            };
            const from_c = gpa.dupe(u8, src) catch {
                gpa.free(raw);
                failed += 1;
                continue;
            };
            const step: UndoStep = switch (op) {
                .dup, .paste => .{ .copy = .{ .from = from_c, .to = raw } },
                .trash => .{ .trash = .{ .from = from_c, .trashed = trashedOrNull(gpa, raw) } },
            };
            steps.append(gpa, step) catch {
                step.deinit(gpa);
                failed += 1;
                continue;
            };
            recordStepDirs(gpa, &touched, step);
        }

        const count = steps.items.len;
        if (count > 0) {
            u.clearRedo(gpa);
            try pushBatch(&u.undo_list, gpa, try steps.toOwnedSlice(gpa));
        } else {
            steps.deinit(gpa);
        }
        return .{ .succeeded = count, .failed = failed, .touched_dirs = try touched.toOwnedSlice(gpa) };
    }

    pub fn undo(u: *UndoStack, gpa: std.mem.Allocator) !UndoOutcome {
        return u.replayBatch(gpa, true);
    }

    pub fn redo(u: *UndoStack, gpa: std.mem.Allocator) !UndoOutcome {
        return u.replayBatch(gpa, false);
    }

    fn replayBatch(u: *UndoStack, gpa: std.mem.Allocator, is_undo: bool) !UndoOutcome {
        const src_list = if (is_undo) &u.undo_list else &u.redo_list;
        const dst_list = if (is_undo) &u.redo_list else &u.undo_list;
        const steps = src_list.pop() orelse return .{};
        defer gpa.free(steps);

        var next_steps: std.ArrayList(UndoStep) = .empty;
        errdefer {
            for (next_steps.items) |st| st.deinit(gpa);
            next_steps.deinit(gpa);
        }
        var touched: std.ArrayList([]u8) = .empty;
        errdefer freeDirList(gpa, &touched);

        var succeeded: usize = 0;
        var failed: usize = 0;
        var first_err: ?anyerror = null;
        for (0..steps.len) |fwd| {
            var step = steps[if (is_undo) steps.len - 1 - fwd else fwd];
            const res = if (is_undo) applyUndoStep(gpa, step) else applyRedoStep(gpa, &step);
            if (res) |_| {
                succeeded += 1;
                recordStepDirs(gpa, &touched, step);
                next_steps.append(gpa, step) catch step.deinit(gpa);
            } else |err| {
                failed += 1;
                if (first_err == null) first_err = err;
                step.deinit(gpa);
            }
        }

        if (next_steps.items.len > 0) {
            if (is_undo) std.mem.reverse(UndoStep, next_steps.items);
            try pushBatch(dst_list, gpa, try next_steps.toOwnedSlice(gpa));
        } else {
            next_steps.deinit(gpa);
        }

        const status: UndoStatus = if (failed == 0) .ok else if (succeeded > 0) .partial else .failed;
        return .{
            .status = status,
            .succeeded = succeeded,
            .failed = failed,
            .first_err = first_err,
            .touched_dirs = try touched.toOwnedSlice(gpa),
        };
    }
};
