//! Tests for `ui.image` device-pixel sizing in the atlas and decode budgeting.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const images = @import("images.zig");

const ViewState = struct {
    bytes: []const u8,
    fn view(s: *ViewState, c: *ui.Context) void {
        _ = ui.image(c, .{ .key = "icon", .bytes = s.bytes, .max_width = 15, .max_height = 15, .radius = 0, .scale = 0.5 });
    }
};

test "ui.image at 15 pt packs side 30 at scale 2 and side 15 at scale 1" {
    const gpa = testing.allocator;
    const raw = try gpa.alloc(u8, 64 * 64 * 4);
    defer gpa.free(raw);
    @memset(raw, 200);
    const png = try ui.png.encode(gpa, .{ .bytes = raw, .width = 64, .height = 64 });
    defer gpa.free(png);

    const k = images.Images.key("icon");
    {
        var s: ViewState = .{ .bytes = png };
        var t: ui.Tester = undefined;
        try t.init(gpa, ui.View.init(&s, ViewState.view), .{ .width = 100, .height = 100, .scale = 2 });
        defer t.deinit();
        t.frame();
        try testing.expect(t.ctx.text.images.entries.get(.{ .key = k, .side = 30 }).?.entry != null);
    }
    {
        var s: ViewState = .{ .bytes = png };
        var t: ui.Tester = undefined;
        try t.init(gpa, ui.View.init(&s, ViewState.view), .{ .width = 100, .height = 100, .scale = 1 });
        defer t.deinit();
        t.frame();
        try testing.expect(t.ctx.text.images.entries.get(.{ .key = k, .side = 15 }).?.entry != null);
    }
}

const BudgetState = struct {
    bytes: []const u8,
    fn view(s: *BudgetState, c: *ui.Context) void {
        for (0..9) |i| {
            _ = ui.image(c, .{ .key = c.print("icon.{d}", .{i}), .bytes = s.bytes, .max_width = 15, .max_height = 15, .radius = 0, .scale = 0.5 });
        }
    }
};

test "decode budget limits to 8 decodes per frame and requests next frame" {
    const gpa = testing.allocator;
    const raw = try gpa.alloc(u8, 16 * 16 * 4);
    defer gpa.free(raw);
    @memset(raw, 200);
    const png = try ui.png.encode(gpa, .{ .bytes = raw, .width = 16, .height = 16 });
    defer gpa.free(png);

    var s: BudgetState = .{ .bytes = png };
    var t: ui.Tester = undefined;
    try t.init(gpa, ui.View.init(&s, BudgetState.view), .{ .width = 200, .height = 200, .scale = 2 });
    defer t.deinit();
    try testing.expectEqual(@as(usize, 8), t.ctx.text.images.entries.count());
    try testing.expect(t.ctx.text.images.wants_frame);
    t.frame();
    try testing.expectEqual(@as(usize, 9), t.ctx.text.images.entries.count());
    try testing.expect(!t.ctx.text.images.wants_frame);
}

test "sink uploads survive render after pre-sink pixels allocation" {
    if (@import("build_options").portable or @import("builtin").os.tag != .macos) return;
    const gpa = testing.allocator;
    const raw = try gpa.alloc(u8, 16 * 16 * 4);
    defer gpa.free(raw);
    @memset(raw, 220);
    const png = try ui.png.encode(gpa, .{ .bytes = raw, .width = 16, .height = 16 });
    defer gpa.free(png);

    var s: BudgetState = .{ .bytes = png };
    var t: ui.Tester = undefined;
    // Frame 1 runs with sink == null, allocating im.pixels and decoding 8 of 9 icons.
    try t.init(gpa, ui.View.init(&s, BudgetState.view), .{ .width = 200, .height = 200, .scale = 2, .dark = true });
    defer t.deinit();
    // Sync the first 8 icons into images_texture, then attach the direct GPU sink for icon.8.
    t.renderer.syncImages(&t.text.images);
    t.text.images.sink = .{ .ctx = &t.renderer, .upload = @TypeOf(t.renderer).uploadImage };
    t.frame();
    const px = try t.render(gpa);
    defer px.deinit(gpa);
    const k8 = images.Images.key("icon.8");
    const e6 = t.ctx.text.images.entries.get(.{ .key = k8, .side = 30 }).?.entry.?;
    var r6: ?ui.Rect = null;
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .image => |im| if (im.key == k8) {
            r6 = n.rect;
        },
        else => {},
    };
    try testing.expect(e6.uv[0] > 0);
    const rect = r6.?;
    const cx: usize = @intFromFloat(@round((rect.x + rect.w * 0.5) * 2));
    const cy: usize = @intFromFloat(@round((rect.y + rect.h * 0.5) * 2));
    const idx = (cy * px.width + cx) * 4;
    try testing.expect(px.bytes[idx] > 180 and px.bytes[idx + 1] > 180 and px.bytes[idx + 2] > 180);
}

const RawState = struct {
    pixels: images.Source.Pixels,
    ok: bool = true,
    fn view(s: *RawState, c: *ui.Context) void {
        s.ok = ui.image(c, .{
            .key = "raw",
            .source = .{ .pixels = s.pixels },
            .max_width = 16,
            .max_height = 16,
            .radius = 0,
            .scale = 1,
        });
    }
};

test "raw pixels pack into atlas and match source BGRA without decoding" {
    const gpa = testing.allocator;
    const px = [_]u8{
        10, 20, 30, 255, 40,  50,  60,  200,
        70, 80, 90, 150, 100, 110, 120, 255,
    };
    var s: RawState = .{ .pixels = .{ .bgra = &px, .width = 2, .height = 2 } };
    var t: ui.Tester = undefined;
    try t.init(gpa, ui.View.init(&s, RawState.view), .{ .width = 100, .height = 100, .scale = 1 });
    defer t.deinit();
    try testing.expect(s.ok);
    try testing.expectEqual(@as(usize, 0), t.ctx.text.images.headers.count());
    try testing.expectEqual(@as(u32, 8), t.ctx.text.images.decodes_left);
    const k = images.Images.key("raw");
    const e = t.ctx.text.images.entries.get(.{ .key = k, .side = 2 }).?.entry.?;
    const ax: usize = @intFromFloat(@round(e.uv[0] * images.size));
    const ay: usize = @intFromFloat(@round(e.uv[1] * images.size));
    try testing.expectEqualSlices(u8, px[0..8], t.ctx.text.images.pixels[((ay + 0) * images.size + ax) * 4 ..][0..8]);
    try testing.expectEqualSlices(u8, px[8..16], t.ctx.text.images.pixels[((ay + 1) * images.size + ax) * 4 ..][0..8]);
}

const RawBudgetState = struct {
    pixels: images.Source.Pixels,
    fn view(s: *RawBudgetState, c: *ui.Context) void {
        for (0..10) |i| {
            _ = ui.image(c, .{
                .key = c.print("raw.{d}", .{i}),
                .source = .{ .pixels = s.pixels },
                .max_width = 16,
                .max_height = 16,
                .radius = 0,
                .scale = 1,
            });
        }
    }
};

test "raw pixels bypass the 8-per-frame decode budget" {
    const gpa = testing.allocator;
    var px: [64]u8 = undefined;
    for (0..16) |i| @memcpy(px[i * 4 ..][0..4], &[_]u8{ 1, 2, 3, 255 });
    var s: RawBudgetState = .{ .pixels = .{ .bgra = &px, .width = 4, .height = 4 } };
    var t: ui.Tester = undefined;
    try t.init(gpa, ui.View.init(&s, RawBudgetState.view), .{ .width = 200, .height = 200, .scale = 1 });
    defer t.deinit();
    try testing.expectEqual(@as(usize, 10), t.ctx.text.images.entries.count());
    try testing.expect(!t.ctx.text.images.wants_frame);
    try testing.expectEqual(@as(u32, 8), t.ctx.text.images.decodes_left);
    try testing.expectEqual(@as(usize, 0), t.ctx.text.images.headers.count());
}

test "raw pixels support stride, scale down, reject invalid input, and repack after trimDecoded" {
    const gpa = testing.allocator;
    var im: images.Images = .{ .gpa = gpa };
    defer im.deinit();

    const padded = [_]u8{
        11, 22, 33, 255, 44,  55,  66,  255, 0xaa, 0xaa, 0xaa, 0xaa,
        77, 88, 99, 255, 110, 120, 130, 255, 0xbb, 0xbb, 0xbb, 0xbb,
    };
    const stride_src: images.Source = .{ .pixels = .{ .bgra = &padded, .width = 2, .height = 2, .stride = 12 } };
    const k_stride = images.Images.key("stride");
    const e_stride = im.get(k_stride, stride_src, 2).?;
    const sx: usize = @intFromFloat(@round(e_stride.uv[0] * images.size));
    const sy: usize = @intFromFloat(@round(e_stride.uv[1] * images.size));
    try testing.expectEqualSlices(u8, padded[0..8], im.pixels[((sy + 0) * images.size + sx) * 4 ..][0..8]);
    try testing.expectEqualSlices(u8, padded[12..20], im.pixels[((sy + 1) * images.size + sx) * 4 ..][0..8]);

    const short = [_]u8{ 1, 2, 3, 4 };
    const invalids = [_]images.Source.Pixels{
        .{ .bgra = &short, .width = 0, .height = 1 },
        .{ .bgra = &padded, .width = 2, .height = 2, .stride = 4 },
        .{ .bgra = &short, .width = 2, .height = 2 },
    };
    for (invalids, 0..) |bad, i| {
        const k_bad = k_stride + 1 + i;
        try testing.expect(im.info(k_bad, .{ .pixels = bad }) == null);
        try testing.expect(im.get(k_bad, .{ .pixels = bad }, 16) == null);
        var rs: RawState = .{ .pixels = bad };
        var t: ui.Tester = undefined;
        try t.init(gpa, ui.View.init(&rs, RawState.view), .{ .width = 64, .height = 64, .scale = 1 });
        defer t.deinit();
        try testing.expect(!rs.ok);
    }

    const big = try gpa.alloc(u8, 64 * 64 * 4);
    defer gpa.free(big);
    @memset(big, 180);
    const e_big = im.get(images.Images.key("big-raw"), .{ .pixels = .{ .bgra = big, .width = 64, .height = 64 } }, 16).?;
    try testing.expectEqual(@as(u32, 64), e_big.width);
    try testing.expectEqual(@as(u32, 64), e_big.height);
    try testing.expectEqual(@as(u32, 16), @as(u32, @intFromFloat(@round((e_big.uv[2] - e_big.uv[0]) * images.size))));
    try testing.expectEqual(@as(u32, 16), @as(u32, @intFromFloat(@round((e_big.uv[3] - e_big.uv[1]) * images.size))));

    im.beginPaint();
    _ = im.get(k_stride, stride_src, 2).?;
    im.trimDecoded();
    im.shelf_y = images.size;
    im.beginPaint();
    try testing.expectEqual(@as(usize, 0), im.entries.count());
    const e_repack = im.get(k_stride, stride_src, 2).?;
    const rx: usize = @intFromFloat(@round(e_repack.uv[0] * images.size));
    const ry: usize = @intFromFloat(@round(e_repack.uv[1] * images.size));
    try testing.expectEqualSlices(u8, padded[0..8], im.pixels[((ry + 0) * images.size + rx) * 4 ..][0..8]);
    try testing.expectEqualSlices(u8, padded[12..20], im.pixels[((ry + 1) * images.size + rx) * 4 ..][0..8]);
}
