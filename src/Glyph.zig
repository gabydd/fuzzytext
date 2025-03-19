const std = @import("std");
const Font = @import("Font.zig");

const Glyph = @This();
x_min: i16,
y_min: i16,
x_max: i16,
y_max: i16,
x_coords_start: u32,
y_coords_start: u32,
flags_start: u32,
end_points_start: u32,
contours: u16,
num_coords: u32,
pub fn iter(data: *const Glyph, font: *const Font) GlyphIterator {
    return .init(data, font);
}
const GlyphPart = struct {
    x: i32,
    y: i32,
    on_curve: bool,
    contour: u16,
};
const GlyphIterator = struct {
    data: *const Glyph,
    end_point: u16,
    contour: u16,
    flag_i: u32,
    flag_repeat: u8,
    repeat_coord: CoordFlag,
    idx: u16,
    x: i32,
    y: i32,
    x_coords_offset: u32,
    y_coords_offset: u32,
    pub fn init(data: *const Glyph, font: *const Font) GlyphIterator {
        var reader = font.fontReader(data.end_points_start);
        return .{
            .data = data,
            .end_point = reader.read(u16),
            .contour = 0,
            .idx = 0,
            .x = 0,
            .y = 0,
            .flag_repeat = 0,
            .flag_i = 0,
            .repeat_coord = undefined,
            .x_coords_offset = data.x_coords_start,
            .y_coords_offset = data.y_coords_start,
        };
    }

    pub fn done(it: *GlyphIterator) bool {
        return it.idx >= it.data.num_coords;
    }

    pub fn next(it: *GlyphIterator, font: *const Font) ?GlyphPart {
        if (it.done()) return null;

        if (it.idx > it.end_point) {
            it.contour += 1;
            var reader = font.fontReader(it.data.end_points_start);
            it.end_point = reader.readFrom(u16, it.contour * 2);
        }

        const flag = blk: {
            if (it.flag_repeat > 0) {
                it.flag_repeat -= 1;
                break :blk it.repeat_coord;
            }
            var reader = font.fontReader(it.data.flags_start);
            const coord: CoordFlag = @bitCast(reader.readFrom(u8, it.flag_i));
            if (coord.repeat) {
                it.flag_repeat = reader.read(u8);
            }
            it.repeat_coord = coord;
            it.flag_i += 1;
            break :blk coord;
        };
        {
            var reader = font.fontReader(it.x_coords_offset);
            if (flag.x_short) {
                const coord = reader.read(u8);
                it.x += coord * flag.xSign();
            } else {
                if (!flag.x_same_or_positive) {
                    const coord = reader.read(i16);
                    it.x += coord;
                }
            }
            it.x_coords_offset = reader.offset;
        }
        {
            var reader = font.fontReader(it.y_coords_offset);
            if (flag.y_short) {
                const coord = reader.read(u8);
                it.y += coord * flag.ySign();
            } else {
                if (!flag.y_same_or_positive) {
                    const coord = reader.read(i16);
                    it.y += coord;
                }
            }
            it.y_coords_offset = reader.offset;
        }
        it.idx += 1;

        return .{
            .contour = it.contour,
            .x = it.x,
            .y = it.y,
            .on_curve = flag.on_curve,
        };
    }
};

const Coord = @Vector(2, i32);
const Bezier = struct {
    p0: Coord,
    p1: Coord,
    p2: Coord,
    fn fromLine(p0: Coord, p2: Coord) Bezier {
        return .{
            .p0 = p0,
            .p1 = (p0 + p2) / @as(Coord, @splat(2)),
            .p2 = p2,
        };
    }
};
const BezierIterator = struct {
    glyph: GlyphIterator,
    idx: u16,
    last: ?GlyphPart,
    first: ?GlyphPart,
    fn init(glyph: *const Glyph, font: *const Font) BezierIterator {
        return .{
            .glyph = .init(glyph, font),
            .idx = 0,
            .last = null,
            .first = null,
        };
    }
    fn next(it: *BezierIterator, font: *const Font) ?Bezier {
        if (it.last == null) it.last = it.glyph.next(font);
        if (it.first == null) it.first = it.last;

        const start = it.last orelse return null;
        std.debug.assert(start.on_curve);
        const middle_maybe = it.glyph.next(font);
        defer if (middle_maybe == null) {
            it.last = null;
        };

        const middle = middle_maybe orelse it.first orelse return null;
        if (start.contour != it.glyph.contour) {
            it.last = middle;
            defer it.first = middle;
            return .fromLine(.{ start.x, start.y }, .{ it.first.?.x, it.first.?.y });
        }
        if (middle.on_curve) {
            it.last = middle;
            return .fromLine(.{ start.x, start.y }, .{ middle.x, middle.y });
        }
        var peek = it.glyph;
        const end = peek.next(font) orelse return null;
        if (start.contour != peek.contour) {
            _ = it.glyph.next(font);
            it.last = end;
            defer it.first = end;
            return .{ .p0 = .{ start.x, start.y }, .p1 = .{ middle.x, middle.y }, .p2 = .{ it.first.?.x, it.first.?.y } };
        }

        if (end.on_curve) {
            _ = it.glyph.next(font);
            it.last = end;
            return .{ .p0 = .{ start.x, start.y }, .p1 = .{ middle.x, middle.y }, .p2 = .{ end.x, end.y } };
        }

        it.last = .{
            .x = @divTrunc((middle.x + end.x), 2),
            .y = @divTrunc((middle.y + end.y), 2),
            .on_curve = true,
            .contour = it.glyph.contour,
        };
        return .{ .p0 = .{ start.x, start.y }, .p1 = .{ middle.x, middle.y }, .p2 = .{ it.last.?.x, it.last.?.y } };
    }
};

pub const RenderedGlyph = struct {
    bitmap: []const [4]u8,
    width: u32,
    height: u32,
};

pub fn renderGlyph(glyph: *const Glyph, font: *const Font, alloc: std.mem.Allocator) !RenderedGlyph {
    const height: u32 = @intCast(glyph.y_max - glyph.y_min + 48);
    const width: u32 = @intCast(glyph.x_max - glyph.x_min + 48);
    const bitmap = try alloc.alloc([4]u8, width * height);
    @memset(bitmap, .{ 0, 0, 0, 0xFF });
    var it = glyph.iter(font);
    while (it.next(font)) |coord| {
        const cx: u32 = @intCast(coord.x - glyph.x_min + 24);
        const cy: u32 = @intCast(coord.y - glyph.y_min + 24);
        for (0..16) |xs| {
            for (0..16) |ys| {
                bitmap[std.math.clamp(cy + ys -% 8, 0, height - 1) * width + std.math.clamp(cx + xs -% 8, 0, width - 1)] = if (coord.on_curve) @splat(0xFF) else .{ 0xFF, 0x00, 0x00, 0xFF };
            }
        }
    }
    return .{
        .height = height,
        .width = width,
        .bitmap = bitmap,
    };
}

pub fn renderOutline(glyph: *const Glyph, font: *const Font, alloc: std.mem.Allocator) !RenderedGlyph {
    const height: u32 = @intCast(glyph.y_max - glyph.y_min + 48);
    const width: u32 = @intCast(glyph.x_max - glyph.x_min + 48);
    const bitmap = try alloc.alloc([4]u8, width * height);
    @memset(bitmap, .{ 0, 0, 0, 0xFF });
    var it: BezierIterator = .init(glyph, font);
    while (it.next(font)) |bezier| {
        const cx0: u32 = @intCast(bezier.p0[0] - glyph.x_min + 24);
        const cy0: u32 = @intCast(bezier.p0[1] - glyph.y_min + 24);
        for (0..16) |xs| {
            for (0..16) |ys| {
                bitmap[std.math.clamp(cy0 + ys -% 8, 0, height - 1) * width + std.math.clamp(cx0 + xs -% 8, 0, width - 1)] = @splat(0xFF);
            }
        }
        const cx1: u32 = @intCast(bezier.p1[0] - glyph.x_min + 24);
        const cy1: u32 = @intCast(bezier.p1[1] - glyph.y_min + 24);
        for (0..16) |xs| {
            for (0..16) |ys| {
                bitmap[std.math.clamp(cy1 + ys -% 8, 0, height - 1) * width + std.math.clamp(cx1 + xs -% 8, 0, width - 1)] = .{ 0xFF, 0x00, 0x00, 0xFF };
            }
        }
        const cx2: u32 = @intCast(bezier.p2[0] - glyph.x_min + 24);
        const cy2: u32 = @intCast(bezier.p2[1] - glyph.y_min + 24);
        for (0..16) |xs| {
            for (0..16) |ys| {
                bitmap[std.math.clamp(cy2 + ys -% 8, 0, height - 1) * width + std.math.clamp(cx2 + xs -% 8, 0, width - 1)] = @splat(0xFF);
            }
        }
    }
    return .{
        .height = height,
        .width = width,
        .bitmap = bitmap,
    };
}

pub const CoordFlag = packed struct {
    on_curve: bool,
    x_short: bool,
    y_short: bool,
    repeat: bool,
    x_same_or_positive: bool,
    y_same_or_positive: bool,
    overlap: bool,
    reserved: bool,
    fn xSign(flag: CoordFlag) i16 {
        return if (flag.x_short and flag.x_same_or_positive) 1 else -1;
    }
    fn ySign(flag: CoordFlag) i16 {
        return if (flag.y_short and flag.y_same_or_positive) 1 else -1;
    }
};
