const std = @import("std");

extern "c" fn dlopen(path: [*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;
extern "c" fn CFRelease(cf: *const anyopaque) void;
extern "c" fn dispatch_queue_create(label: [*:0]const u8, attr: ?*const anyopaque) ?*anyopaque;
extern "c" fn dispatch_queue_attr_make_with_qos_class(attr: ?*const anyopaque, qos: u32, rel_prio: c_int) ?*const anyopaque;
extern "c" fn dispatch_release(obj: *anyopaque) void;
extern "c" fn dispatch_sync_f(queue: *anyopaque, ctx: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;

fn drained(_: ?*anyopaque) callconv(.c) void {}

const RTLD_LAZY: c_int = 1;
const QOS_CLASS_UTILITY: u32 = 0x11;
const CREATE_FLAG_NO_DEFER: u32 = 0x2;
const kCFStringEncodingUTF8: u32 = 0x08000100;

pub const MUST_SCAN_SUBDIRS: u32 = 0x1;
pub const USER_DROPPED: u32 = 0x2;
pub const KERNEL_DROPPED: u32 = 0x4;
pub const HISTORY_DONE: u32 = 0x10;

pub const Event = struct {
    path: []u8,
    flags: u32,
    id: u64,
    stream: u32,
};

const FSEventStreamContext = extern struct {
    version: isize,
    info: ?*anyopaque,
    retain: ?*const anyopaque,
    release: ?*const anyopaque,
    copy_description: ?*const anyopaque,
};

const CallbackFn = *const fn (?*anyopaque, ?*anyopaque, usize, ?*anyopaque, [*]const u32, [*]const u64) callconv(.c) void;
const CreateFn = *const fn (?*const anyopaque, CallbackFn, *const FSEventStreamContext, *const anyopaque, u64, f64, u32) callconv(.c) ?*anyopaque;
const SetQueueFn = *const fn (*anyopaque, *anyopaque) callconv(.c) void;
const StartFn = *const fn (*anyopaque) callconv(.c) u8;
const StopFn = *const fn (*anyopaque) callconv(.c) void;
const InvalidateFn = *const fn (*anyopaque) callconv(.c) void;
const ReleaseFn = *const fn (*anyopaque) callconv(.c) void;
const CurrentIdFn = *const fn () callconv(.c) u64;
const CFStrFn = *const fn (?*const anyopaque, [*:0]const u8, u32) callconv(.c) ?*const anyopaque;
const CFArrFn = *const fn (?*const anyopaque, [*]const *const anyopaque, isize, ?*const anyopaque) callconv(.c) ?*const anyopaque;

const Api = struct {
    create: CreateFn,
    set_queue: SetQueueFn,
    start: StartFn,
    stop: StopFn,
    invalidate: InvalidateFn,
    release: ReleaseFn,
    current_id: CurrentIdFn,
    string: CFStrFn,
    array: CFArrFn,
    array_callbacks: ?*const anyopaque,
};

var api_loaded: std.atomic.Value(u8) = .init(0);
var api_mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER;
var api_val: Api = undefined;

fn sym(comptime T: type, h: *anyopaque, name: [*:0]const u8) ?T {
    const p = dlsym(h, name) orelse return null;
    return @ptrCast(@alignCast(p));
}

fn loadApi() ?*const Api {
    if (api_loaded.load(.acquire) == 1) return &api_val;
    _ = std.c.pthread_mutex_lock(&api_mutex);
    defer _ = std.c.pthread_mutex_unlock(&api_mutex);
    if (api_loaded.load(.acquire) == 1) return &api_val;
    const cs = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY) orelse return null;
    const cf = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_LAZY) orelse return null;
    const cb_ptr = dlsym(cf, "kCFTypeArrayCallBacks");
    api_val = .{
        .create = sym(CreateFn, cs, "FSEventStreamCreate") orelse return null,
        .set_queue = sym(SetQueueFn, cs, "FSEventStreamSetDispatchQueue") orelse return null,
        .start = sym(StartFn, cs, "FSEventStreamStart") orelse return null,
        .stop = sym(StopFn, cs, "FSEventStreamStop") orelse return null,
        .invalidate = sym(InvalidateFn, cs, "FSEventStreamInvalidate") orelse return null,
        .release = sym(ReleaseFn, cs, "FSEventStreamRelease") orelse return null,
        .current_id = sym(CurrentIdFn, cs, "FSEventsGetCurrentEventId") orelse return null,
        .string = sym(CFStrFn, cf, "CFStringCreateWithCString") orelse return null,
        .array = sym(CFArrFn, cf, "CFArrayCreate") orelse return null,
        .array_callbacks = cb_ptr,
    };
    api_loaded.store(1, .release);
    return &api_val;
}

pub fn currentId() u64 {
    const a = loadApi() orelse return 0;
    return a.current_id();
}

pub const SinkFn = *const fn (ctx: ?*anyopaque, batch: []Event) void;

pub const Stream = struct {
    raw: *anyopaque,
    queue: *anyopaque,
    gpa: std.mem.Allocator,
    stream_id: u32,
    sink: SinkFn,
    sink_ctx: ?*anyopaque,

    pub fn destroy(s: *Stream) void {
        if (loadApi()) |a| {
            a.stop(s.raw);
            a.invalidate(s.raw);
            dispatch_sync_f(s.queue, null, drained);
            a.release(s.raw);
        }
        dispatch_release(s.queue);
        s.gpa.destroy(s);
    }
};

fn onEvents(
    _: ?*anyopaque,
    info_ptr: ?*anyopaque,
    n: usize,
    paths_ptr: ?*anyopaque,
    flags: [*]const u32,
    ids: [*]const u64,
) callconv(.c) void {
    const s: *Stream = @ptrCast(@alignCast(info_ptr orelse return));
    const paths: [*]const [*:0]const u8 = @ptrCast(@alignCast(paths_ptr orelse return));
    const batch = s.gpa.alloc(Event, n) catch return;
    var filled: usize = 0;
    for (0..n) |i| {
        const span = std.mem.span(paths[i]);
        const dup = s.gpa.dupe(u8, span) catch continue;
        batch[filled] = .{
            .path = dup,
            .flags = flags[i],
            .id = ids[i],
            .stream = s.stream_id,
        };
        filled += 1;
    }
    s.sink(s.sink_ctx, batch[0..filled]);
    for (batch[0..filled]) |ev| s.gpa.free(ev.path);
    s.gpa.free(batch);
}

pub fn watch(
    gpa: std.mem.Allocator,
    since: u64,
    latency: f64,
    stream_id: u32,
    sink: SinkFn,
    sink_ctx: ?*anyopaque,
) !*Stream {
    const a = loadApi() orelse return error.Unavailable;
    const s = try gpa.create(Stream);
    errdefer gpa.destroy(s);

    const root = a.string(null, "/", kCFStringEncodingUTF8) orelse return error.CFStringFailed;
    defer CFRelease(root);
    var items = [_]*const anyopaque{root};
    const arr = a.array(null, &items, 1, a.array_callbacks) orelse return error.CFArrayFailed;
    defer CFRelease(arr);

    const attr = dispatch_queue_attr_make_with_qos_class(null, QOS_CLASS_UTILITY, 0);
    const q = dispatch_queue_create("dev.fpcmotif.zigder.fsevents", attr) orelse return error.QueueFailed;
    errdefer dispatch_release(q);

    s.* = .{
        .raw = undefined,
        .queue = q,
        .gpa = gpa,
        .stream_id = stream_id,
        .sink = sink,
        .sink_ctx = sink_ctx,
    };

    const ctx: FSEventStreamContext = .{
        .version = 0,
        .info = s,
        .retain = null,
        .release = null,
        .copy_description = null,
    };
    const raw = a.create(null, onEvents, &ctx, arr, since, latency, CREATE_FLAG_NO_DEFER) orelse return error.StreamCreateFailed;
    s.raw = raw;
    a.set_queue(raw, q);
    if (a.start(raw) == 0) {
        a.invalidate(raw);
        a.release(raw);
        return error.StreamStartFailed;
    }
    return s;
}
