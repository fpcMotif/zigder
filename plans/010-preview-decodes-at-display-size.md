# Plan 010: The image preview decodes at display size

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before the next step.
> If a "STOP conditions" item occurs, stop and report. Do not improvise. When
> done, update the row for this plan in `plans/README.md`.
>
> **Drift check (run first)**: this checkout is a JJ workspace with
> uncommitted changes. Compare each excerpt in "Current state" with the live
> file. A mismatch in text is a STOP condition. A moved line number is not.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: perf
- **Planned at**: commit `33844b4` plus the uncommitted working tree, 2026-11-26

## Why this matters

The inspector and the gallery show a preview of the selected image. The code
loads the file with `NSImage`, asks for a full-size `CGImage`, and then draws
it into a small bitmap. A full-size decode needs width × height × 4 bytes. A
48-megapixel photo needs about 190 MB for a moment, on the UI thread. This
figure comes from reading the code; it was not measured in the app.

ImageIO can decode straight to a small size. Memory and time then depend on
the preview size, not on the file.

## Current state

- `src/fs/media.zig` (309 lines) — rasterizers for icons, PDF pages, and images.
- `src/ui/inspector.zig:158` and `src/ui/gallery.zig:93` — call `media.preview.show(path, kind, mtime, max_w, max_h)` with pixel sizes.
- `build.zig:47-48` — links frameworks for the app module.

`src/fs/media.zig:294-309`, the function to replace:

```zig
fn nativeImage(_: ?*anyopaque, gpa: std.mem.Allocator, path: []const u8, max_w: u32, max_h: u32) ?Bitmap {
    if (comptime nanoui.ui.portable) return null;
    const pool = objc.Pool.push();
    defer pool.pop();
    const ns_image = objc.msg(?objc.Object, objc.alloc("NSImage"), "initWithContentsOfFile:", .{objc.nsString(path)}) orelse return null;
    defer objc.release(ns_image);
    const cg = objc.msg(?*anyopaque, ns_image, "CGImageForProposedRect:context:hints:", .{ @as(?*objc.CGRect, null), @as(?objc.Object, null), @as(?objc.Object, null) }) orelse return null;
    const w: f64 = @floatFromInt(CGImageGetWidth(cg));
    const h: f64 = @floatFromInt(CGImageGetHeight(cg));
    if (w < 1 or h < 1) return null;
    const scale = fit(w, h, max_w, max_h, false);
    const canvas = Canvas.open(gpa, @intFromFloat(@max(1, @round(w * scale))), @intFromFloat(@max(1, @round(h * scale)))) orelse return null;
    defer CGContextRelease(canvas.ctx);
    CGContextDrawImage(canvas.ctx, canvas.frame(), cg);
    return canvas.out;
}
```

`src/fs/media.zig:250-253`, the helper it uses (`enlarge = false` means a
small image is never scaled up):

```zig
fn fit(w: f64, h: f64, max_w: u32, max_h: u32, enlarge: bool) f64 {
    const scale = @min(@as(f64, @floatFromInt(max_w)) / w, @as(f64, @floatFromInt(max_h)) / h);
    return if (enlarge) scale else @min(1, scale);
}
```

`src/fs/media.zig:89-91`, the existing public wrapper for icons, used as the
pattern for a new wrapper:

```zig
pub fn rasterizeIcon(gpa: std.mem.Allocator, full: []const u8, side: u32) ?[]u8 {
    return nativeIcon(null, gpa, full, side);
}
```

`build.zig:47-48`:

```zig
        mod.linkFramework("CoreServices", .{});
        mod.linkFramework("CoreGraphics", .{});
```

Conventions:

- C functions are declared `extern "c" fn` at the top of the file (`media.zig:8-26`). Objective-C calls use `objc.msg(ReturnType, receiver, "selector:", .{args})`. An `NSURL` from a path: `objc.msg(?objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(path)})` (`media.zig:273`).
- `nanoui.ui.portable` is a build option. Native code returns early when it is true. A native-only test starts with `if (comptime ui.portable) return error.SkipZigTest;` (`src/tests/ui.zig:306`).
- 600-line limit per file. No new comments. No Markdown edits except `plans/README.md`.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| All checks | `mise exec -- zig build check` | exit 0 |
| One test | `mise exec -- zig build test -Dtest-filter="native image preview"` | exit 0 |

## Scope

**In scope**: `src/fs/media.zig`, `build.zig` (one `linkFramework` line), `src/tests/media.zig`, `plans/README.md` (status row).

**Out of scope**: `nativePdfPage`, `nativeIcon`, `PreviewCache`, the two view files. Moving the decode off the UI thread.

## Git workflow

JJ workspace. Do not commit or move changes. Subject style:
`perf(zig): decode image previews at display size`.

## Steps

### Step 1: Write the failing test

Add to `src/fs/media.zig`:

```zig
pub fn rasterizeImage(gpa: std.mem.Allocator, path: []const u8, max_w: u32, max_h: u32) ?Bitmap {
    return nativeImage(null, gpa, path, max_w, max_h);
}
```

Add to `src/tests/media.zig`: `test "media: native image preview fits the box and keeps the aspect ratio"`.

1. Skip when `ui.portable` is true.
2. Create a `support.TempDir`. Make a 1600 × 800 PNG with `support.sh("sips -s format png -z 800 1600 /System/Library/CoreServices/DefaultDesktop.heic --out '{s}/wide.png' >/dev/null", .{root})`. When the command fails, return `error.SkipZigTest`.
3. Call `fs_media.rasterizeImage(gpa, path, 400, 400)`. Free `bgra` at the end.
4. Expect `w == 400` and `h == 200`.
5. Call it again with `max_w = 4000, max_h = 4000`. Expect `w == 1600` and `h == 800` (no enlargement).

**Verify**: `mise exec -- zig build test -Dtest-filter="native image preview"` → passes with the old code too. This test pins the behaviour before the change.

### Step 2: Decode with ImageIO

1. In `build.zig`, add `mod.linkFramework("ImageIO", .{});` after the `CoreGraphics` line.
2. In `src/fs/media.zig`, declare:
   - `extern "c" fn CGImageSourceCreateWithURL(url: objc.Object, options: ?objc.Object) ?*anyopaque;`
   - `extern "c" fn CGImageSourceCreateThumbnailAtIndex(src: *anyopaque, index: usize, options: ?objc.Object) ?*anyopaque;`
   - `extern "c" fn CGImageRelease(image: *anyopaque) void;`
   - `extern "c" fn CFRelease(obj: *anyopaque) void;`
   - `extern "c" var kCGImageSourceCreateThumbnailFromImageAlways: objc.Object;`
   - `extern "c" var kCGImageSourceCreateThumbnailWithTransform: objc.Object;`
   - `extern "c" var kCGImageSourceThumbnailMaxPixelSize: objc.Object;`
3. Replace the body of `nativeImage` after the autorelease pool lines:
   - Make the `NSURL` as in `media.zig:273`. Return null on failure.
   - `CGImageSourceCreateWithURL(url, null)`; `defer CFRelease(src)`.
   - Build the options: `const opts = objc.msg(objc.Object, objc.class("NSMutableDictionary"), "dictionary", .{});` then three `setObject:forKey:` calls. The two boolean keys take `objc.msg(objc.Object, objc.class("NSNumber"), "numberWithBool:", .{@as(objc.BOOL, 1)})`. The size key takes `numberWithUnsignedInt:` with `@max(max_w, max_h)`.
   - `CGImageSourceCreateThumbnailAtIndex(src, 0, opts)`; `defer CGImageRelease(cg)`.
   - Keep the last seven lines of the old body unchanged, from `const w: f64` to `return canvas.out;`.

If `objc.BOOL` rejects the literal `1`, look at how `src/main.zig:122-127`
uses `objc.BOOL` and match it.

**Verify**: `mise exec -- zig build test -Dtest-filter="native image preview"` → exit 0. Then `mise exec -- zig build check` → exit 0.

### Step 3: Confirm the old path is gone

**Verify**: `rg -n "initWithContentsOfFile" src/fs/media.zig` prints nothing.

## Done criteria

- [ ] `mise exec -- zig build check` exits 0
- [ ] `mise exec -- zig build` exits 0
- [ ] `rg -n "initWithContentsOfFile" src/fs/media.zig` prints nothing
- [ ] `rg -n "CGImageSourceCreateThumbnailAtIndex" src/fs/media.zig` prints two matches (declaration and call)
- [ ] The new test passes and is not skipped on this machine
- [ ] Only in-scope files changed
- [ ] `plans/README.md` status row updated

## STOP conditions

- The link step fails for a `kCGImageSource…` symbol after the framework line is added.
- The Step 1 test fails with the old code. The pinned numbers are then wrong for this machine; report the sizes you got.
- After Step 2 the test reports a size that differs by more than 1 pixel.
- An excerpt does not match the live file.

## Maintenance notes

- `kCGImageSourceCreateThumbnailWithTransform` applies the photo's rotation tag. The old code also showed rotated photos upright, through `NSImage`.
- The decode still runs on the UI thread, once per selected file. A large RAW file can still take tens of milliseconds. Moving it to a worker is a separate change that needs a placeholder state in `PreviewCache`.
- `PreviewCache` keeps one drawn bitmap and one retired bitmap (`media.zig:140-197`). At the inspector's size that is under 2 MB.
