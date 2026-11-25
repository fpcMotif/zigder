const std = @import("std");
const fs_ops = @import("../fs/ops.zig");
const fs_undo = @import("../fs/undo.zig");
const walk = @import("../index/walk.zig");
const engine_mod = @import("../index/engine.zig");
const search_mod = @import("../search/search.zig");
const app_mod = @import("../app/app.zig");
const commands = @import("../app/commands.zig");
const support = @import("support.zig");

extern "c" fn lstat(path: [*:0]const u8, buf: *std.c.Stat) c_int;

test "fileops: batch duplicate undoes and redoes all items in one transaction" {
    const gpa = std.testing.allocator;
    const tmp = try support.TempDir.create("/tmp/zigder-fop");
    defer tmp.cleanup();
    const root = tmp.path();

    try support.sh("printf 'a' > '{s}/one.txt' && printf 'b' > '{s}/two.txt' && printf 'c' > '{s}/three.txt'", .{ root, root, root });

    var p1: [128]u8 = undefined;
    var p2: [128]u8 = undefined;
    var p3: [128]u8 = undefined;
    const s1 = try std.fmt.bufPrint(&p1, "{s}/one.txt", .{root});
    const s2 = try std.fmt.bufPrint(&p2, "{s}/two.txt", .{root});
    const s3 = try std.fmt.bufPrint(&p3, "{s}/three.txt", .{root});

    var undo: fs_undo.UndoStack = .{};
    defer undo.deinit(gpa);

    var batch = try undo.duplicateBatch(gpa, &.{ s1, s2, s3 });
    defer batch.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), batch.succeeded);
    try std.testing.expectEqual(@as(usize, 0), batch.failed);
    try std.testing.expectEqual(@as(usize, 1), batch.touched_dirs.len);
    try std.testing.expectEqualStrings(root, batch.touched_dirs[0]);
    try std.testing.expect(support.existsAt("{s}/one copy.txt", .{root}));
    try std.testing.expect(support.existsAt("{s}/two copy.txt", .{root}));
    try std.testing.expect(support.existsAt("{s}/three copy.txt", .{root}));

    var undo1 = try undo.undo(gpa);
    defer undo1.deinit(gpa);
    try std.testing.expectEqual(fs_undo.UndoStatus.ok, undo1.status);
    try std.testing.expectEqual(@as(usize, 3), undo1.succeeded);
    try std.testing.expectEqual(@as(usize, 1), undo1.touched_dirs.len);
    try std.testing.expect(!support.existsAt("{s}/one copy.txt", .{root}));
    try std.testing.expect(!support.existsAt("{s}/two copy.txt", .{root}));
    try std.testing.expect(!support.existsAt("{s}/three copy.txt", .{root}));

    var undo_empty = try undo.undo(gpa);
    defer undo_empty.deinit(gpa);
    try std.testing.expectEqual(fs_undo.UndoStatus.empty, undo_empty.status);

    var redo1 = try undo.redo(gpa);
    defer redo1.deinit(gpa);
    try std.testing.expectEqual(fs_undo.UndoStatus.ok, redo1.status);
    try std.testing.expectEqual(@as(usize, 3), redo1.succeeded);
    try std.testing.expect(support.existsAt("{s}/one copy.txt", .{root}));
    try std.testing.expect(support.existsAt("{s}/two copy.txt", .{root}));
    try std.testing.expect(support.existsAt("{s}/three copy.txt", .{root}));
}

test "fileops: partial batch redo keeps succeeded items undoable and reports touched dirs" {
    const gpa = std.testing.allocator;
    const tmp = try support.TempDir.create("/tmp/zigder-part");
    defer tmp.cleanup();
    const root = tmp.path();

    try support.sh("printf 'aa' > '{s}/a.txt' && printf 'bb' > '{s}/b.txt'", .{ root, root });

    var pa: [128]u8 = undefined;
    var pb: [128]u8 = undefined;
    const a_path = try std.fmt.bufPrint(&pa, "{s}/a.txt", .{root});
    const b_path = try std.fmt.bufPrint(&pb, "{s}/b.txt", .{root});

    var undo: fs_undo.UndoStack = .{};
    defer undo.deinit(gpa);

    var batch = try undo.duplicateBatch(gpa, &.{ a_path, b_path });
    defer batch.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), batch.succeeded);

    var undo1 = try undo.undo(gpa);
    defer undo1.deinit(gpa);
    try std.testing.expectEqual(fs_undo.UndoStatus.ok, undo1.status);

    try support.sh("printf 'mine' > '{s}/a copy.txt'", .{root});
    var redo1 = try undo.redo(gpa);
    defer redo1.deinit(gpa);
    try std.testing.expectEqual(fs_undo.UndoStatus.partial, redo1.status);
    try std.testing.expectEqual(@as(usize, 1), redo1.succeeded);
    try std.testing.expectEqual(@as(usize, 1), redo1.failed);
    try std.testing.expectEqual(@as(?anyerror, error.DestinationExists), redo1.first_err);
    try std.testing.expectEqual(@as(usize, 1), redo1.touched_dirs.len);
    try std.testing.expectEqualStrings(root, redo1.touched_dirs[0]);
    try std.testing.expect(support.existsAt("{s}/b copy.txt", .{root}));

    var undo2 = try undo.undo(gpa);
    defer undo2.deinit(gpa);
    try std.testing.expectEqual(fs_undo.UndoStatus.ok, undo2.status);
    try std.testing.expectEqual(@as(usize, 1), undo2.succeeded);
    try std.testing.expect(!support.existsAt("{s}/b copy.txt", .{root}));
    try std.testing.expect(support.existsAt("{s}/a copy.txt", .{root}));
}

test "fileops: cross-folder undo syncs mutated folder in Engine outside currentPath" {
    const gpa = std.testing.allocator;
    const tmp = try support.TempDir.create("/tmp/zigder-xundo");
    defer tmp.cleanup();
    const root = tmp.path();

    try support.sh("mkdir -p '{s}/docs' '{s}/other' && printf 'g' > '{s}/docs/guide.md' && printf 'o' > '{s}/other/note.txt'", .{ root, root, root, root });

    var idx_buf: [128]u8 = undefined;
    const idx_path = try std.fmt.bufPrint(&idx_buf, "{s}/xundo.zidx", .{root});
    try support.buildRootedIndex(gpa, root, idx_path, 1);

    var engine = try engine_mod.Engine.initHeadlessWithIndex(gpa, idx_path);
    defer engine.deinit();

    var state = try app_mod.AppState.init(gpa, &engine, root, root);
    defer state.deinit();

    var docs_buf: [128]u8 = undefined;
    const docs = try std.fmt.bufPrint(&docs_buf, "{s}/docs", .{root});
    var other_buf: [128]u8 = undefined;
    const other = try std.fmt.bufPrint(&other_buf, "{s}/other", .{root});

    try state.navigateTo(docs, true);
    state.selectRow(0, false, false);
    try std.testing.expect(commands.dispatch(&state, .{ .action = .duplicate }));
    try std.testing.expect(support.existsAt("{s}/docs/guide copy.md", .{root}));

    var res: search_mod.SearchResults = .{};
    defer res.deinit(gpa);
    try engine.runSearch(gpa, root, "guide copy", null, 10, &res);
    try std.testing.expectEqual(@as(usize, 1), res.hits.items.len);

    try state.navigateTo(other, true);
    try std.testing.expect(commands.dispatch(&state, .{ .action = .undo }));
    try std.testing.expect(!support.existsAt("{s}/docs/guide copy.md", .{root}));

    try engine.runSearch(gpa, root, "guide copy", null, 10, &res);
    try std.testing.expectEqual(@as(usize, 0), res.hits.items.len);
}

test "fileops: pasteBatch groups copied files and reports destination dir" {
    const gpa = std.testing.allocator;
    const tmp = try support.TempDir.create("/tmp/zigder-paste");
    defer tmp.cleanup();
    const root = tmp.path();

    try support.sh("mkdir -p '{s}/src_dir' '{s}/dst_dir' && printf '1' > '{s}/src_dir/one.txt' && printf '2' > '{s}/src_dir/two.txt'", .{ root, root, root, root });

    var p1: [128]u8 = undefined;
    var p2: [128]u8 = undefined;
    var pd: [128]u8 = undefined;
    const s1 = try std.fmt.bufPrint(&p1, "{s}/src_dir/one.txt", .{root});
    const s2 = try std.fmt.bufPrint(&p2, "{s}/src_dir/two.txt", .{root});
    const dst = try std.fmt.bufPrint(&pd, "{s}/dst_dir", .{root});

    var undo: fs_undo.UndoStack = .{};
    defer undo.deinit(gpa);

    var batch = try undo.pasteBatch(gpa, &.{ s1, s2 }, dst);
    defer batch.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), batch.succeeded);
    try std.testing.expectEqual(@as(usize, 1), batch.touched_dirs.len);
    try std.testing.expectEqualStrings(dst, batch.touched_dirs[0]);
    try std.testing.expect(support.existsAt("{s}/one.txt", .{dst}));
    try std.testing.expect(support.existsAt("{s}/two.txt", .{dst}));

    var undo1 = try undo.undo(gpa);
    defer undo1.deinit(gpa);
    try std.testing.expectEqual(fs_undo.UndoStatus.ok, undo1.status);
    try std.testing.expectEqual(@as(usize, 2), undo1.succeeded);
    try std.testing.expect(!support.existsAt("{s}/one.txt", .{dst}));
    try std.testing.expect(!support.existsAt("{s}/two.txt", .{dst}));
    try std.testing.expect(support.existsAt("{s}", .{s1}));
    try std.testing.expect(support.existsAt("{s}", .{s2}));
}

test "fileops: typed create_dir and create_file undo empty items and guard non-empty ones" {
    const gpa = std.testing.allocator;
    const tmp = try support.TempDir.create("/tmp/zigder-crt");
    defer tmp.cleanup();
    const root = tmp.path();

    var undo: fs_undo.UndoStack = .{};
    defer undo.deinit(gpa);

    const dir = try undo.createFolder(gpa, root, "empty_dir");
    defer gpa.free(dir);
    var undo1 = try undo.undo(gpa);
    defer undo1.deinit(gpa);
    try std.testing.expectEqual(fs_undo.UndoStatus.ok, undo1.status);
    try std.testing.expect(!support.existsAt("{s}", .{dir}));

    var redo1 = try undo.redo(gpa);
    defer redo1.deinit(gpa);
    try std.testing.expectEqual(fs_undo.UndoStatus.ok, redo1.status);
    try std.testing.expect(support.existsAt("{s}", .{dir}));

    const file = try undo.createFile(gpa, root, "note.txt");
    defer gpa.free(file);
    try support.sh("printf 'data' > '{s}'", .{file});
    var undo2 = try undo.undo(gpa);
    defer undo2.deinit(gpa);
    try std.testing.expectEqual(fs_undo.UndoStatus.failed, undo2.status);
    try std.testing.expectEqual(@as(?anyerror, error.FileNotEmpty), undo2.first_err);
    try std.testing.expect(support.existsAt("{s}", .{file}));
}

fn flagMountListDir(gpa: std.mem.Allocator, path: []const u8, out: *walk.Listing) bool {
    if (!walk.listOne(gpa, path, out)) return false;
    for (out.ents.items) |*r| {
        if (std.mem.eql(u8, out.entName(r.*), "mnt_child")) {
            r.kind |= walk.FLAG_MOUNT;
        }
    }
    return true;
}

fn crossDevChildStat(pz: [*:0]const u8) ?fs_ops.DevT {
    var st: std.c.Stat = undefined;
    if (lstat(pz, &st) != 0) return null;
    if (std.mem.endsWith(u8, std.mem.span(pz), "/mnt_child")) return st.dev + 1;
    return st.dev;
}

fn mountRootStat(pz: [*:0]const u8) ?fs_ops.DevT {
    var st: std.c.Stat = undefined;
    if (lstat(pz, &st) != 0) return null;
    if (std.mem.endsWith(u8, std.mem.span(pz), "/mount_root")) return st.dev + 1;
    return st.dev;
}

fn dirHasExactChild(gpa: std.mem.Allocator, parent: []const u8, target: []const u8) bool {
    var listing: walk.Listing = .{ .id = 0 };
    defer listing.deinit(gpa);
    if (!walk.listOne(gpa, parent, &listing)) return false;
    for (listing.ents.items) |r| {
        if (std.mem.eql(u8, listing.entName(r), target)) return true;
    }
    return false;
}

test "fileops: H10 deleteImmediately refuses FLAG_MOUNT children, cross-device dirs, and mount targets without deleting volume contents" {
    const gpa = std.testing.allocator;
    const tmp = try support.TempDir.create("/tmp/zigder-h10");
    defer tmp.cleanup();
    const root = tmp.path();

    try support.sh(
        "cd '{s}' && mkdir -p tree/mnt_child mount_root outside sub && " ++
            "printf 'k' > tree/keep.txt && printf 'm' > tree/mnt_child/precious.txt && " ++
            "printf 'r' > mount_root/keep.txt && printf 's' > outside/safe.txt && " ++
            "printf 'n' > sub/nested.txt && ln -s '{s}/outside' sub/link_out",
        .{ root, root },
    );

    var p1: [128]u8 = undefined;
    const tree_dir = try std.fmt.bufPrint(&p1, "{s}/tree", .{root});
    var p2: [128]u8 = undefined;
    const mount_root = try std.fmt.bufPrint(&p2, "{s}/mount_root", .{root});
    var p3: [128]u8 = undefined;
    const sub_dir = try std.fmt.bufPrint(&p3, "{s}/sub", .{root});

    try std.testing.expectError(error.MountPoint, fs_ops.deleteImmediatelyWith(gpa, tree_dir, .{ .list_dir = flagMountListDir }));
    try std.testing.expect(support.existsAt("{s}/tree/mnt_child/precious.txt", .{root}));
    try std.testing.expect(support.existsAt("{s}/tree/keep.txt", .{root}));

    try std.testing.expectError(error.MountPoint, fs_ops.deleteImmediatelyWith(gpa, tree_dir, .{ .stat_dev = crossDevChildStat }));
    try std.testing.expect(support.existsAt("{s}/tree/mnt_child/precious.txt", .{root}));

    try std.testing.expectError(error.MountPoint, fs_ops.deleteImmediatelyWith(gpa, mount_root, .{ .stat_dev = mountRootStat }));
    try std.testing.expect(support.existsAt("{s}/mount_root/keep.txt", .{root}));

    try fs_ops.deleteImmediately(gpa, sub_dir);
    try std.testing.expect(!support.existsAt("{s}/sub", .{root}));
    try std.testing.expect(support.existsAt("{s}/outside/safe.txt", .{root}));
}

test "fileops: H9 case-only rename works on APFS with undo and redo while preserving hardlink collision checks" {
    const gpa = std.testing.allocator;
    const tmp = try support.TempDir.create("/tmp/zigder-h9");
    defer tmp.cleanup();
    const root = tmp.path();

    try support.sh(
        "mkdir -p '{s}/sub' && printf 'hello' > '{s}/foo.txt' && printf 'child' > '{s}/sub/item.txt' && " ++
            "printf 'same' > '{s}/a.txt' && ln '{s}/a.txt' '{s}/b.txt'",
        .{ root, root, root, root, root, root },
    );

    var pf: [128]u8 = undefined;
    const foo_path = try std.fmt.bufPrint(&pf, "{s}/foo.txt", .{root});
    var ps: [128]u8 = undefined;
    const sub_path = try std.fmt.bufPrint(&ps, "{s}/sub", .{root});
    var pa: [128]u8 = undefined;
    const a_path = try std.fmt.bufPrint(&pa, "{s}/a.txt", .{root});
    var pb: [128]u8 = undefined;
    const b_path = try std.fmt.bufPrint(&pb, "{s}/b.txt", .{root});

    var undo: fs_undo.UndoStack = .{};
    defer undo.deinit(gpa);

    const upper = try undo.renameItem(gpa, foo_path, "Foo.txt");
    defer gpa.free(upper);
    try std.testing.expect(dirHasExactChild(gpa, root, "Foo.txt"));
    try std.testing.expect(!dirHasExactChild(gpa, root, "foo.txt"));

    var undo1 = try undo.undo(gpa);
    defer undo1.deinit(gpa);
    try std.testing.expectEqual(fs_undo.UndoStatus.ok, undo1.status);
    try std.testing.expect(dirHasExactChild(gpa, root, "foo.txt"));
    try std.testing.expect(!dirHasExactChild(gpa, root, "Foo.txt"));

    var redo1 = try undo.redo(gpa);
    defer redo1.deinit(gpa);
    try std.testing.expectEqual(fs_undo.UndoStatus.ok, redo1.status);
    try std.testing.expect(dirHasExactChild(gpa, root, "Foo.txt"));
    try std.testing.expect(!dirHasExactChild(gpa, root, "foo.txt"));

    const upper_dir = try undo.renameItem(gpa, sub_path, "Sub");
    defer gpa.free(upper_dir);
    try std.testing.expect(dirHasExactChild(gpa, root, "Sub"));
    try std.testing.expect(!dirHasExactChild(gpa, root, "sub"));

    var undo2 = try undo.undo(gpa);
    defer undo2.deinit(gpa);
    try std.testing.expectEqual(fs_undo.UndoStatus.ok, undo2.status);
    try std.testing.expect(dirHasExactChild(gpa, root, "sub"));

    try std.testing.expectError(error.NameTaken, fs_ops.renameItem(gpa, a_path, "b.txt"));
    try std.testing.expectError(error.DestinationExists, fs_ops.moveToExactPath(gpa, a_path, b_path));
    try std.testing.expect(dirHasExactChild(gpa, root, "a.txt"));
    try std.testing.expect(dirHasExactChild(gpa, root, "b.txt"));
}

test "safety: entry creation and rename reject traversal/nul names and failed moves preserve source" {
    const gpa = std.testing.allocator;
    const tmp = try support.TempDir.create("/tmp/zigder-safeop");
    defer tmp.cleanup();
    const root = tmp.path();

    try support.sh(
        "mkdir -p '{s}/sub' '{s}/ro_parent/dir' '{s}/dst' && " ++
            "printf 'keep' > '{s}/sub/file.txt' && printf 'precious' > '{s}/ro_parent/dir/precious.txt'",
        .{ root, root, root, root, root },
    );
    defer support.sh("chmod 0755 '{s}/ro_parent'", .{root}) catch {};

    var sub_buf: [128]u8 = undefined;
    const sub_dir = try std.fmt.bufPrint(&sub_buf, "{s}/sub", .{root});
    var file_buf: [128]u8 = undefined;
    const file_path = try std.fmt.bufPrint(&file_buf, "{s}/sub/file.txt", .{root});

    for ([_][]const u8{ "", ".", "..", "../escaped", "nested/dir", "bad\x00name" }) |bad| {
        try std.testing.expectError(error.InvalidName, fs_ops.createFolder(gpa, sub_dir, bad));
        try std.testing.expectError(error.InvalidName, fs_ops.createFile(gpa, sub_dir, bad));
        try std.testing.expectError(error.InvalidName, fs_ops.renameItem(gpa, file_path, bad));
    }
    try std.testing.expect(!support.existsAt("{s}/escaped", .{root}));
    try std.testing.expect(support.existsAt("{s}/sub/file.txt", .{root}));

    var into_self_buf: [128]u8 = undefined;
    const into_self = try std.fmt.bufPrint(&into_self_buf, "{s}/sub/child/into_self", .{root});
    try support.sh("mkdir -p '{s}/sub/child'", .{root});
    try std.testing.expectError(error.InvalidDestination, fs_ops.moveToExactPath(gpa, sub_dir, into_self));
    try std.testing.expect(!support.existsAt("{s}", .{into_self}));
    try std.testing.expect(support.existsAt("{s}/sub/file.txt", .{root}));

    try support.sh("chmod 0555 '{s}/ro_parent'", .{root});
    var ro_dir_buf: [128]u8 = undefined;
    const ro_dir = try std.fmt.bufPrint(&ro_dir_buf, "{s}/ro_parent/dir", .{root});
    var dst_dir_buf: [128]u8 = undefined;
    const dst_dir = try std.fmt.bufPrint(&dst_dir_buf, "{s}/dst/dir", .{root});
    try std.testing.expectError(error.RenameFailed, fs_ops.moveToExactPath(gpa, ro_dir, dst_dir));
    try std.testing.expect(support.existsAt("{s}/ro_parent/dir/precious.txt", .{root}));
    try std.testing.expect(!support.existsAt("{s}/dst/dir", .{root}));
}
