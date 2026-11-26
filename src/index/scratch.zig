const std = @import("std");

extern "c" fn mkstemp(template: [*:0]u8) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn ftruncate(fd: c_int, len: i64) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn mmap(addr: ?*anyopaque, len: usize, prot: c_int, flags: c_int, fd: c_int, off: i64) usize;
extern "c" fn munmap(addr: *anyopaque, len: usize) c_int;
extern "c" fn confstr(name: c_int, buf: [*]u8, len: usize) usize;

const PROT_READ_WRITE: c_int = 0x1 | 0x2;
const MAP_SHARED: c_int = 0x0001;
const MAP_PRIVATE: c_int = 0x0002;
const MAP_NOCACHE: c_int = 0x0400;
const MAP_ANON: c_int = 0x1000;
const MAP_FAILED: usize = std.math.maxInt(usize);
const CS_DARWIN_USER_TEMP_DIR: c_int = 65537;

const Chunk = struct {
    prev: ?*Chunk,
    len: usize,
};

pub const Scratch = struct {
    fd: c_int = -1,
    file_len: usize = 0,
    head: ?*Chunk = null,
    end: usize = 0,
    limit: usize = 0,

    const min_chunk: usize = 8 << 20;

    pub fn init() Scratch {
        var buf: [1100]u8 = undefined;
        const n = confstr(CS_DARWIN_USER_TEMP_DIR, &buf, 1024);
        const dir: []const u8 = if (n > 1 and n <= 1024) buf[0 .. n - 1] else "/tmp/";
        var tbuf: [1100]u8 = undefined;
        const sep: []const u8 = if (dir[dir.len - 1] == '/') "" else "/";
        const template = std.fmt.bufPrintSentinel(&tbuf, "{s}{s}zigder-scratch.XXXXXX", .{ dir, sep }, 0) catch return .{};
        const fd = mkstemp(template.ptr);
        if (fd >= 0) _ = unlink(template.ptr);
        return .{ .fd = fd };
    }

    pub fn deinit(s: *Scratch) void {
        var cur = s.head;
        while (cur) |c| {
            const prev = c.prev;
            _ = munmap(c, c.len);
            cur = prev;
        }
        if (s.fd >= 0) _ = close(s.fd);
        s.* = .{};
    }

    pub fn allocator(s: *Scratch) std.mem.Allocator {
        return .{ .ptr = s, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn map(s: *Scratch, len: usize) usize {
        if (s.fd >= 0) {
            const next_len = s.file_len + len;
            if (ftruncate(s.fd, @intCast(next_len)) == 0) {
                const at = mmap(null, len, PROT_READ_WRITE, MAP_SHARED | MAP_NOCACHE, s.fd, @intCast(s.file_len));
                if (at != MAP_FAILED) {
                    s.file_len = next_len;
                    return at;
                }
            }
        }
        return mmap(null, len, PROT_READ_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    }

    fn grow(s: *Scratch, need: usize) bool {
        const page = std.heap.pageSize();
        const want = @max(need + @sizeOf(Chunk), min_chunk);
        const len = std.mem.alignForward(usize, want, page);
        const at = s.map(len);
        if (at == MAP_FAILED) return false;
        const chunk: *Chunk = @ptrFromInt(at);
        chunk.* = .{ .prev = s.head, .len = len };
        s.head = chunk;
        s.end = at + @sizeOf(Chunk);
        s.limit = at + len;
        return true;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        const s: *Scratch = @ptrCast(@alignCast(ctx));
        var start = alignment.forward(s.end);
        if (s.head == null or start + len > s.limit) {
            if (!s.grow(len + alignment.toByteUnits())) return null;
            start = alignment.forward(s.end);
        }
        s.end = start + len;
        return @ptrFromInt(start);
    }

    fn resize(ctx: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
        const s: *Scratch = @ptrCast(@alignCast(ctx));
        const base = @intFromPtr(memory.ptr);
        if (base + memory.len != s.end) return new_len <= memory.len;
        if (base + new_len > s.limit) return false;
        s.end = base + new_len;
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        return if (resize(ctx, memory, alignment, new_len, ra)) memory.ptr else null;
    }

    fn free(ctx: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
        const s: *Scratch = @ptrCast(@alignCast(ctx));
        const base = @intFromPtr(memory.ptr);
        if (base + memory.len == s.end) s.end = base;
    }
};
